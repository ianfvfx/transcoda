#!/bin/bash
# One-time setup for Transcoda's "Transcribe SRTs" preset.
#
# Run this once per user account on each Mac that will use Transcribe SRTs
# (double-click it in Finder). It creates an isolated Python environment
# just for the transcription tool, so it can never conflict with anything
# else on this Mac's Python installation.
#
# Safe to run again later (e.g. to update faster-whisper) — it reuses the
# existing environment rather than starting over.

set -e

VENV_DIR="$HOME/Library/Application Support/Transcoda/whisper-env"

echo "Setting up Transcoda's transcription environment..."
echo ""

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 was not found on this Mac's PATH."
    echo "Transcoda's Transcribe SRTs preset needs Python 3 installed first."
    read -n 1 -s -r -p "Press any key to close..."
    exit 1
fi

if [ -d "$VENV_DIR" ]; then
    echo "Environment already exists at:"
    echo "  $VENV_DIR"
    echo "Updating faster-whisper..."
else
    echo "Creating a new environment at:"
    echo "  $VENV_DIR"
    mkdir -p "$(dirname "$VENV_DIR")"
    python3 -m venv "$VENV_DIR"
fi

echo ""
echo "Installing faster-whisper (this can take a few minutes)..."
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install faster-whisper

echo ""
echo "Done! Transcoda's \"Transcribe SRTs\" preset is ready to use."
echo ""
echo "Note: the very first time you actually transcribe a file, it will"
echo "download the Whisper speech-recognition model (several hundred MB)"
echo "from the internet. This only happens once — after that it's cached"
echo "on this Mac and every future transcription is fast, with no internet"
echo "needed."
echo ""
read -n 1 -s -r -p "Press any key to close this window..."
