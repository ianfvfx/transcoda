from pathlib import Path
import sys
from faster_whisper import WhisperModel

def main():
    if len(sys.argv) not in (2, 3):
        print(f"Usage: python {Path(sys.argv[0]).name} <video_file> [output_srt_path]")
        sys.exit(1)

    input_file = Path(sys.argv[1])

    if not input_file.exists():
        print(f"Error: File not found: {input_file}")
        sys.exit(1)

    # Optional second argument lets a caller (Transcoda) control exactly where
    # the .srt lands, matching its own output-location settings. Falls back to
    # the original behavior (next to the input) for standalone CLI use.
    output_file = Path(sys.argv[2]) if len(sys.argv) == 3 else input_file.with_suffix(".srt")
    output_file.parent.mkdir(parents=True, exist_ok=True)

    # Initialize model (Using CPU/Int8 as requested)
    print("Loading model...")
    model = WhisperModel("small", device="cpu", compute_type="int8")

    print(f"Transcribing {input_file.name}...")
    # beam_size=5 is the default and improves accuracy
    segments, info = model.transcribe(str(input_file), word_timestamps=True)

    def fmt(t):
        # Isolate the total seconds and the exact millisecond remainder first
        total_seconds = int(t)
        ms = int(round((t - total_seconds) * 1000))
    
        # If rounding pushes ms to 1000, roll it over into total_seconds
        if ms == 1000:
            ms = 0
            total_seconds += 1

        # Now calculate hours, minutes, and seconds from the total_seconds
        h = total_seconds // 3600
        m = (total_seconds % 3600) // 60
        s = total_seconds % 60
    
        return f"{h:02}:{m:02}:{s:02},{ms:03}"

    # Open file and consume the generator directly inside the block
    with open(output_file, "w", encoding="utf-8") as f:
        for i, segment in enumerate(segments, start=1):
            f.write(f"{i}\n")
            f.write(f"{fmt(segment.start)} --> {fmt(segment.end)}\n")
            f.write(f"{segment.text.strip()}\n\n")

    print(f"Successfully created: {output_file}")

if __name__ == "__main__":
    main()
