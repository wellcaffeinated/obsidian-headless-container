#!/bin/bash
# Polls `obsidian version` until it succeeds or the timeout elapses.
# Usage: wait-for-obsidian.sh [timeout_seconds]
set -euo pipefail

timeout="${1:-120}"
OBSIDIAN_BIN="${OBSIDIAN_BIN:-/opt/obsidian/obsidian}"
WARMUP="${WARMUP:-5}"

# Give the main Obsidian process time to claim its single-instance lock,
# so secondary `obsidian` invocations are forwarded via IPC rather than
# racing to become the primary instance.
sleep "${WARMUP}"

deadline=$(( $(date +%s) + timeout ))
while [[ $(date +%s) -lt ${deadline} ]]; do
    if "${OBSIDIAN_BIN}" --no-sandbox version >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done
exit 1
