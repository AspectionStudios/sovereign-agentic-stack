#!/bin/sh
# tiktok-video.sh — download a TikTok video (MP4) and optionally list comments.
#
# Usage: tiktok-video.sh <video-url> [comments-count]
#   <video-url>     full TikTok URL or a vt.tiktok.com / t/ share link
#   [comments-count] if given, also fetch and print that many comments
#
# How it works: resolves share links to the canonical URL, asks the tikwm
# API for the direct play URL, downloads with curl (the TikTok CDN rejects
# requests without a browser User-Agent and a tikwm Referer), and — when a
# comment count is given — prints "author: text" lines from tikwm's
# comment/list endpoint. JSON parsing is done with python3.
#
# Downloads land in ./downloads/ relative to where you run it.

set -eu

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

if [ $# -lt 1 ]; then
    echo "usage: $0 <video-url> [comments-count]" >&2
    exit 1
fi
URL_IN="$1"
COMMENTS="${2:-}"

# Resolve share links (tiktok.com/t/..., vt.tiktok.com/...) to the real URL.
URL=$(curl -s -L -o /dev/null -w "%{url_effective}" -A "$UA" "$URL_IN")

# URL-encode for use as a query parameter.
ENC=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$URL")

# Ask tikwm for the video metadata; pull out the direct play URL and the id.
META=$(curl -s -A "$UA" "https://www.tikwm.com/api/?url=$ENC")
PLAY=$(printf '%s' "$META" | python3 -c 'import sys, json; d = json.load(sys.stdin); print(d["data"]["play"])' 2>/dev/null || true)
VID=$(printf '%s' "$META" | python3 -c 'import sys, json; d = json.load(sys.stdin); print(d["data"].get("id", "video"))' 2>/dev/null || echo video)

if [ -z "${PLAY:-}" ]; then
    echo "error: tikwm returned no play URL for $URL" >&2
    exit 1
fi

mkdir -p downloads
OUT="downloads/$VID.mp4"
curl -s -L -A "$UA" -e "https://www.tikwm.com/" -o "$OUT" "$PLAY"
echo "downloaded: $OUT"

# Optional: comments.
if [ -n "$COMMENTS" ]; then
    curl -s -A "$UA" "https://www.tikwm.com/api/comment/list?url=$ENC&count=$COMMENTS" \
    | python3 -c '
import sys, json
d = json.load(sys.stdin)
for c in d.get("data", {}).get("comments", []):
    user = c.get("user", {})
    author = user.get("unique_id") or user.get("nickname") or "?"
    text = c.get("text", "")
    print(author + ": " + text)
'
fi
