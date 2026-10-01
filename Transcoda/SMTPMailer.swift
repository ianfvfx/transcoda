import Foundation
import CFNetwork

enum SMTPError: LocalizedError {
    case connectionFailed(String)
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "SMTP connection failed: \(message)"
        case .serverRejected(let message): return "SMTP server rejected the message: \(message)"
        }
    }
}

// Minimal SMTP client for Microsoft 365 "Direct Send" — an unauthenticated
// connection straight to Exchange Online Protection's inbound endpoint,
// accepted purely because the sending machine's IP falls within
// blackkitestudios.com's SPF record. No login, no credentials, no app
// password. Ported from autoframeio/autoframeio/mailer.py (the standalone
// Python tool at /Users/ian.fallon/Documents/Claude/autoframeio) — see that
// project's README.md for why this only works from a network whose egress
// IP is SPF-authorized (the office network); anywhere else, this either
// fails outright or lands as spam.
//
// Blocking — call only from a background thread. Uses Foundation's
// CFStream-backed Stream API rather than Network.framework: STARTTLS needs
// to upgrade an already-open plaintext connection to TLS mid-session, which
// Stream supports via `.socketSecurityLevelKey`/kCFStreamPropertySSLSettings
// but NWConnection does not support for a connection already established.
enum SMTPMailer {
    private static let ioTimeout: TimeInterval = 20

    static func send(to addresses: [String], subject: String, body: String) throws {
        var inputStreamRef: InputStream?
        var outputStreamRef: OutputStream?
        Stream.getStreamsToHost(
            withName: AutoFrameIOConstants.smtpHost,
            port: Int(AutoFrameIOConstants.smtpPort),
            inputStream: &inputStreamRef,
            outputStream: &outputStreamRef
        )
        guard let input = inputStreamRef, let output = outputStreamRef else {
            throw SMTPError.connectionFailed("could not create socket streams to \(AutoFrameIOConstants.smtpHost)")
        }

        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
            input.remove(from: .current, forMode: .default)
            output.remove(from: .current, forMode: .default)
        }

        _ = try readReply(input)  // 220 greeting

        try writeLine(output, "EHLO transcoda.local")
        let ehloReply = try readReply(input)

        if ehloReply.uppercased().contains("STARTTLS") {
            try writeLine(output, "STARTTLS")
            _ = try readReply(input)  // 220 ready to start TLS
            try upgradeToTLS(input: input, output: output)
            try writeLine(output, "EHLO transcoda.local")
            _ = try readReply(input)
        }

        try writeLine(output, "MAIL FROM:<\(AutoFrameIOConstants.fromAddress)>")
        _ = try readReply(input)

        for address in addresses {
            try writeLine(output, "RCPT TO:<\(address)>")
            _ = try readReply(input)
        }

        try writeLine(output, "DATA")
        _ = try readReply(input)  // 354

        let message = composeMessage(to: addresses, subject: subject, body: body)
        try writeRaw(output, dotStuffed(message) + "\r\n.\r\n")
        _ = try readReply(input)  // 250 accepted

        try writeLine(output, "QUIT")
        _ = try? readReply(input)
    }

    // MARK: - Message composition

    private static func composeMessage(to addresses: [String], subject: String, body: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let dateHeader = formatter.string(from: Date())

        return """
        From: \(AutoFrameIOConstants.fromAddress)
        To: \(addresses.joined(separator: ", "))
        Subject: \(subject)
        Date: \(dateHeader)
        Content-Type: text/plain; charset=utf-8

        \(body)
        """
    }

    // SMTP DATA framing: any line starting with "." gets an extra "." so it
    // isn't mistaken for the terminating "." line, and every line ends CRLF.
    private static func dotStuffed(_ message: String) -> String {
        message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(".") ? "." + $0 : String($0) }
            .joined(separator: "\r\n")
    }

    // MARK: - TLS upgrade

    private static func upgradeToTLS(input: InputStream, output: OutputStream) throws {
        let settings: [String: Any] = [
            kCFStreamSSLValidatesCertificateChain as String: true,
            kCFStreamSSLPeerName as String: AutoFrameIOConstants.smtpHost,
        ]
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        CFReadStreamSetProperty(input, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary)
        CFWriteStreamSetProperty(output, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary)
    }

    // MARK: - Low-level line I/O

    // CFStream sockets are asynchronous even when driven this "synchronously"
    // — nothing progresses without the run loop being pumped, so every wait
    // below alternates a short run-loop spin with re-checking the stream.
    private static func pumpRunLoop() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    private static func writeLine(_ stream: OutputStream, _ line: String) throws {
        try writeRaw(stream, line + "\r\n")
    }

    private static func writeRaw(_ stream: OutputStream, _ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        let deadline = Date().addingTimeInterval(ioTimeout)
        var bytesWritten = 0
        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            while bytesWritten < data.count {
                if !stream.hasSpaceAvailable {
                    if Date() > deadline { throw SMTPError.connectionFailed("write timed out") }
                    pumpRunLoop()
                    continue
                }
                let n = stream.write(base + bytesWritten, maxLength: data.count - bytesWritten)
                if n < 0 {
                    throw SMTPError.connectionFailed(stream.streamError?.localizedDescription ?? "write failed")
                }
                bytesWritten += n
            }
        }
    }

    // Reads until a full SMTP reply has arrived — a multi-line reply uses
    // "250-" continuation lines and a final "250 " (space, not dash) line.
    private static func readReply(_ stream: InputStream) throws -> String {
        var collected = ""
        let deadline = Date().addingTimeInterval(ioTimeout)
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            if !stream.hasBytesAvailable {
                if Date() > deadline { throw SMTPError.connectionFailed("read timed out") }
                pumpRunLoop()
                continue
            }
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n < 0 {
                throw SMTPError.connectionFailed(stream.streamError?.localizedDescription ?? "read failed")
            }
            if n == 0 { break }
            collected += String(bytes: buffer[0..<n], encoding: .utf8) ?? ""

            let lines = collected.split(separator: "\r\n", omittingEmptySubsequences: true)
            if let last = lines.last, last.count >= 4, collected.hasSuffix("\r\n") {
                let codeChar = last[last.index(last.startIndex, offsetBy: 3)]
                if codeChar == " " { break }
            }
        }

        let code = Int(collected.prefix(3)) ?? 0
        guard (200...399).contains(code) else {
            throw SMTPError.serverRejected(collected.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return collected
    }
}
