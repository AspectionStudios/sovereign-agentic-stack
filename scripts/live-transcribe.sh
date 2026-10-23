#!/bin/sh
# live-transcribe.sh — record a slice of a TikTok live and transcribe it.
#
# Usage: live-transcribe.sh <username-or-live-url> [seconds]
#   <username-or-live-url>  e.g. "naru.o_o" or https://www.tiktok.com/@naru.o_o/live
#   [seconds]               how long to record (default 120)
#
# How it works: yt-dlp resolves the live's FLV stream URL (HLS tends to
# return 5XX on TikTok lives; FLV works), ffmpeg records N seconds, the
# audio is extracted as 16kHz mono WAV, and whisper.cpp transcribes it.
# The transcript is printed to stdout; temp files are cleaned up.
#
# whisper.cpp is referenced via $WHISPER_DIR (default ~/workspace/whisper-cpp)
# and is NOT vendored in this repo — build it and drop a model in separately.

set -eu

WHISPER_DIR="${WHISPER_DIR:-$HOME/workspace/whisper-cpp}"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
WHISPER_MODEL="$WHISPER_DIR/models/ggml-tiny.bin"

if [ $# -lt 1 ]; then
    echo "usage: $0 <username-or-live-url> [seconds]" >&2
    exit 1
fi
TARGET="$1"
SECS="${2:-120}"

case "$TARGET" in
    http://*|https://*) LIVE_URL="$TARGET" ;;
    *) LIVE_URL="https://www.tiktok.com/@$TARGET/live" ;;
esac

[ -x "$WHISPER_BIN" ] || { echo "error: whisper-cli not found at $WHISPER_BIN (set WHISPER_DIR)" >&2; exit 1; }
[ -f "$WHISPER_MODEL" ] || { echo "error: whisper model not found at $WHISPER_MODEL" >&2; exit 1; }

# Resolve the stream URL. Empty result = not live (or yt-dlp blocked).
STREAM=$(yt-dlp -g -f flv-hd "$LIVE_URL" 2>/dev/null || true)
if [ -z "$STREAM" ]; then
    echo "error: no FLV stream for $LIVE_URL (user offline?)" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# Record, then extract speech-ready audio.
ffmpeg -y -loglevel error -i "$STREAM" -t "$SECS" -c copy "$TMP/rec.flv"
ffmpeg -y -loglevel error -i "$TMP/rec.flv" -vn -ar 16000 -ac 1 "$TMP/audio.wav"

# Transcribe to a text file and print it.
"$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$TMP/audio.wav" -otxt -of "$TMP/out" >/dev/null 2>&1
cat "$TMP/out.txt"
