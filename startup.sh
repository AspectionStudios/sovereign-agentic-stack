#!/bin/bash
# Sovereign stack startup - run after VM restart
# Restores all background services for the TikTok/Zig stack

set -e

echo "=== Restoring sovereign stack ==="

# 1. SNI forwarder (TLS tunneling through egress proxy) - REQUIRED for Zig client
if ! curl -s -o /dev/null --max-time 3 https://127.0.0.1:443 --insecure 2>/dev/null; then
    echo "Starting SNI forwarder..."
    nohup python3 ~/workspace/tiktoklive/sni_forward.py > /tmp/sni_forward.log 2>&1 &
    sleep 1
fi
echo "SNI forwarder: $(cat /tmp/sni_forward.log 2>/dev/null | head -1)"

# 2. Lightpanda (headless browser, CDP on :9222) - for cookies/JS when needed
if ! curl -s --max-time 3 http://127.0.0.1:9222/json/version > /dev/null 2>&1; then
    echo "Starting Lightpanda..."
    if ! which lightpanda > /dev/null 2>&1; then
        echo "Reinstalling lightpanda..."
        pip install --break-system-packages --quiet lightpanda
    fi
    nohup lightpanda serve --host 127.0.0.1 --port 9222 > /tmp/lp.log 2>&1 &
    sleep 2
fi
echo "Lightpanda: $(curl -s --max-time 3 http://127.0.0.1:9222/json/version 2>/dev/null | head -c 40)"

# 3. Verify Zig toolchain
if [ -x ~/workspace/zig/zig-x86_64-linux-0.15.1/zig ]; then
    echo "Zig: $(~/workspace/zig/zig-x86_64-linux-0.15.1/zig version)"
else
    echo "Zig: MISSING - reinstall from https://ziglang.org/download/"
fi

# 4. Verify live-chat binary
if [ -x ~/workspace/zig/live-chat/zig-out/bin/live-chat ]; then
    echo "live-chat: ready"
else
    echo "live-chat: rebuilding..."
    cd ~/workspace/zig/live-chat && ~/workspace/zig/zig-x86_64-linux-0.15.1/zig build
    echo "live-chat: rebuilt"
fi

# 5. Verify whisper.cpp
if [ -x ~/workspace/whisper-cpp/build/bin/whisper-cli ]; then
    echo "whisper.cpp: ready"
else
    echo "whisper.cpp: MISSING - rebuild with cmake"
fi

echo ""
echo "=== Stack ready ==="
echo "Live chat: ~/workspace/zig/live-chat/zig-out/bin/live-chat <username>"
echo "Example:   ~/workspace/zig/live-chat/zig-out/bin/live-chat naru.o_o"
