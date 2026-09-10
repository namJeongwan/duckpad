#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || "$1" != /* || "$1" != *.app ]]; then
    echo "Usage: $0 /absolute/path/Duckpad.app" >&2
    exit 64
fi
APP="$1"
BINARY="$APP/Contents/MacOS/Duckpad"
test -x "$BINARY"
for LOCALE in en ko ja zh-Hans pt-BR it fr de; do
    RESULT="$(DUCKPAD_LOCALIZATION_SMOKE="$LOCALE" "$BINARY")"
    [[ "$RESULT" == "DUCKPAD_LOCALIZATION_READY=$LOCALE "* ]]
    echo "$RESULT"
done
echo "PASS: all eight languages loaded from the packaged app without opening user sessions"
