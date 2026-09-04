#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PERFORMANCE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/duckpad-performance.XXXXXX")"
trap 'rm -rf "$PERFORMANCE_ROOT"' EXIT

APP="$PERFORMANCE_ROOT/Duckpad.app"
"$SCRIPT_DIR/build_macos_app.sh" --output "$APP" --architecture native >/dev/null
"$SCRIPT_DIR/verify_macos_app.sh" "$APP" >/dev/null

SETTINGS_FILE="$PERFORMANCE_ROOT/settings.json"
RECOVERY_ROOT="$PERFORMANCE_ROOT/recovery"
BOOKMARKS_FILE="$PERFORMANCE_ROOT/document-bookmarks.json"
WORKSPACE_ROOTS_FILE="$PERFORMANCE_ROOT/workspace-roots.json"
EXTENSIONS_ROOT="$PERFORMANCE_ROOT/extensions"
EXTENSION_POLICY_ROOT="$PERFORMANCE_ROOT/extension-policy"
mkdir -p "$RECOVERY_ROOT" "$EXTENSIONS_ROOT" "$EXTENSION_POLICY_ROOT"

WARM_VALUES=()
for ITERATION in 0 1 2 3 4 5; do
    START_SECONDS="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')"
    ERROR_FILE="$PERFORMANCE_ROOT/warm-$ITERATION.stderr"
    set +e
    OUTPUT="$(
        env \
            DUCKPAD_PERFORMANCE_LAUNCH_SMOKE=1 \
            DUCKPAD_SETTINGS_FILE="$SETTINGS_FILE" \
            DUCKPAD_RECOVERY_ROOT="$RECOVERY_ROOT" \
            DUCKPAD_DOCUMENT_BOOKMARKS_FILE="$BOOKMARKS_FILE" \
            DUCKPAD_WORKSPACE_ROOTS_FILE="$WORKSPACE_ROOTS_FILE" \
            DUCKPAD_EXTENSIONS_ROOT="$EXTENSIONS_ROOT" \
            DUCKPAD_EXTENSION_POLICY_ROOT="$EXTENSION_POLICY_ROOT" \
            /usr/bin/perl -e '
                use strict;
                use warnings;
                my $child = fork();
                die "fork failed: $!\n" unless defined $child;
                if ($child == 0) { exec @ARGV; exit 127; }
                $SIG{ALRM} = sub {
                    kill "TERM", $child;
                    select undef, undef, undef, 0.2;
                    kill "KILL", $child if kill 0, $child;
                    waitpid $child, 0;
                    exit 124;
                };
                alarm 10;
                waitpid $child, 0;
                my $status = $?;
                alarm 0;
                exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
            ' "$APP/Contents/MacOS/Duckpad"
    )" 2>"$ERROR_FILE"
    LAUNCH_STATUS=$?
    set -e
    END_SECONDS="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f", time')"
    if [[ "$LAUNCH_STATUS" -ne 0 ]]; then
        sed -n '1,80p' "$ERROR_FILE" >&2
        echo "Warm launch failed or exceeded the 10-second deadline (status $LAUNCH_STATUS)" >&2
        exit "$LAUNCH_STATUS"
    fi
    if ! printf '%s\n' "$OUTPUT" | grep -qx 'DUCKPAD_PERF_READY=1 RECENTS=0'; then
        echo "Warm launch did not reach isolated ready state" >&2
        exit 65
    fi
    VALUE="$(awk -v start="$START_SECONDS" -v end="$END_SECONDS" 'BEGIN { printf "%.3f", (end - start) * 1000 }')"
    if [[ "$ITERATION" -gt 0 ]]; then WARM_VALUES+=("$VALUE"); fi
done

WARM_MAX="$(printf '%s\n' "${WARM_VALUES[@]}" | sort -nr | head -1)"
swift build --package-path "$REPOSITORY_ROOT" -c release --product DuckpadPerformanceBenchmark >/dev/null
BIN_PATH="$(swift build --package-path "$REPOSITORY_ROOT" -c release --show-bin-path)"
"$BIN_PATH/DuckpadPerformanceBenchmark" --warm-launch-ms "$WARM_MAX"
