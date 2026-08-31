#!/bin/bash
# handoff.sh — push the Magic mouse + keyboard from this Mac to another one.
#
#   ./handoff.sh studio.local
#
# Requires: magicswitch installed at the same path on both Macs, and SSH
# (Settings → General → Sharing → Remote Login) enabled on the target, with
# key-based auth so no password prompt appears after your keyboard is gone.

set -euo pipefail

TARGET="${1:?usage: handoff.sh user@host [device ...]}"
shift || true
DEVICES=("$@")
BIN="${MAGICSWITCH_BIN:-/usr/local/bin/magicswitch}"

# 1. Tell the other Mac to start reaching for the device *before* we let go,
#    so the gap where nothing owns the mouse is as short as possible.
ssh -n -o BatchMode=yes "$TARGET" "$BIN grab --timeout 30 ${DEVICES[*]:-}" &
GRAB_PID=$!

sleep 0.3

# 2. Drop the link here, holding it closed long enough that this Mac's HID
#    manager doesn't snatch it back.
"$BIN" release --hold 6 "${DEVICES[@]:-}"

wait "$GRAB_PID" && echo "Handed off to $TARGET." || {
  echo "Target never connected — re-grabbing locally." >&2
  "$BIN" grab --timeout 15 "${DEVICES[@]:-}"
  exit 1
}
