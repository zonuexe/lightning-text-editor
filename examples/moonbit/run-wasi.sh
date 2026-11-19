#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
export PATH="$HOME/.moon/bin:$PATH"

WASM_BIN="_build/wasm/release/build/cmd/wasi/wasi.wasm"
if [ ! -f "$WASM_BIN" ]; then
  echo "Building MoonBit WASI binary..."
  moon build --target wasm --release cmd/wasi
fi

if ! command -v wasmtime >/dev/null 2>&1; then
  echo "Error: wasmtime is not installed. Install with: brew install wasmtime" >&2
  exit 1
fi

TARGET_FILE="${1:-sample.txt}"
COLS="$(tput cols 2>/dev/null || echo 80)"
LINES="$(tput lines 2>/dev/null || echo 24)"

# WASI Preview 1 does not yet standardize termios raw mode, so the host shell
# switches the TTY into raw mode before launching wasmtime and restores it on exit.
if [ -t 0 ]; then
  ORIG_STTY="$(stty -g)"
  CLEANED_UP=0
  cleanup() {
    if [ "$CLEANED_UP" -eq 1 ]; then
      return
    fi
    CLEANED_UP=1
    printf '\033[?2004l\033[?1006l\033[?1002l\033[?1049l\033[?25h\033[0m'
    stty "$ORIG_STTY" 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM HUP
  stty raw -echo
fi

wasmtime --dir=. --env "COLUMNS=$COLS" --env "LINES=$LINES" "$WASM_BIN" "$TARGET_FILE"
