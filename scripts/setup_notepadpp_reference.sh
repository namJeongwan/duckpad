#!/bin/sh
set -eu

REFERENCE_URL=https://github.com/notepad-plus-plus/notepad-plus-plus.git
REFERENCE_COMMIT=dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
TARGET_INPUT=${1:-"$REPOSITORY_ROOT/notepad-plus-plus"}

# Resolve and constrain the target before the first Git command. Only a direct
# child of Duckpad's canonical root is managed; symlinked targets and parents
# cannot redirect clone/checkout outside that boundary.
case "$TARGET_INPUT" in
    /*) TARGET_ABSOLUTE=$TARGET_INPUT ;;
    *) TARGET_ABSOLUTE=$PWD/$TARGET_INPUT ;;
esac

if [ -L "$TARGET_ABSOLUTE" ]; then
    echo "Refusing symlink reference target: $TARGET_INPUT" >&2
    exit 1
fi

TARGET_PARENT=$(dirname -- "$TARGET_ABSOLUTE")
TARGET_NAME=$(basename -- "$TARGET_ABSOLUTE")
if [ ! -d "$TARGET_PARENT" ]; then
    echo "Reference target parent does not exist: $TARGET_PARENT" >&2
    exit 1
fi
TARGET_PARENT=$(CDPATH= cd -- "$TARGET_PARENT" && pwd -P)

if [ -e "$TARGET_ABSOLUTE" ]; then
    if [ ! -d "$TARGET_ABSOLUTE" ]; then
        echo "Reference target is not a directory: $TARGET_INPUT" >&2
        exit 1
    fi
    REFERENCE_TARGET=$(CDPATH= cd -- "$TARGET_ABSOLUTE" && pwd -P)
else
    REFERENCE_TARGET=$TARGET_PARENT/$TARGET_NAME
fi

if [ "$REFERENCE_TARGET" = "/" ] || [ "$REFERENCE_TARGET" = "$REPOSITORY_ROOT" ]; then
    echo "Refusing unsafe reference target: $REFERENCE_TARGET" >&2
    exit 1
fi
if [ "$TARGET_PARENT" != "$REPOSITORY_ROOT" ]; then
    echo "Reference target must be a direct child of Duckpad root: $REFERENCE_TARGET" >&2
    exit 1
fi

if [ ! -e "$REFERENCE_TARGET" ]; then
    git clone --filter=blob:none "$REFERENCE_URL" "$REFERENCE_TARGET"
fi

if [ ! -d "$REFERENCE_TARGET/.git" ]; then
    echo "Reference target is not a standalone Git repository: $REFERENCE_TARGET" >&2
    exit 1
fi

ACTUAL_TOPLEVEL=$(git -C "$REFERENCE_TARGET" rev-parse --show-toplevel 2>/dev/null || true)
ACTUAL_TOPLEVEL=$(CDPATH= cd -- "$ACTUAL_TOPLEVEL" 2>/dev/null && pwd -P || true)
if [ "$ACTUAL_TOPLEVEL" != "$REFERENCE_TARGET" ]; then
    echo "Reference Git root does not match canonical target: $REFERENCE_TARGET" >&2
    exit 1
fi

ORIGIN_URL=$(git -C "$REFERENCE_TARGET" config --get remote.origin.url 2>/dev/null || true)
if [ "$ORIGIN_URL" != "$REFERENCE_URL" ]; then
    echo "Reference target is an unrelated repository: origin=$ORIGIN_URL" >&2
    exit 1
fi

if [ -n "$(git -C "$REFERENCE_TARGET" status --porcelain --untracked-files=all)" ]; then
    echo "Reference repository is dirty before setup; refusing all Git mutation." >&2
    exit 1
fi

CURRENT_COMMIT=$(git -C "$REFERENCE_TARGET" rev-parse HEAD 2>/dev/null || true)
if [ "$CURRENT_COMMIT" != "$REFERENCE_COMMIT" ]; then
    git -C "$REFERENCE_TARGET" fetch --depth=1 origin "$REFERENCE_COMMIT"
    git -C "$REFERENCE_TARGET" checkout --detach "$REFERENCE_COMMIT"
fi

ACTUAL_COMMIT=$(git -C "$REFERENCE_TARGET" rev-parse HEAD)
if [ "$ACTUAL_COMMIT" != "$REFERENCE_COMMIT" ]; then
    echo "Pinned commit verification failed: $ACTUAL_COMMIT" >&2
    exit 1
fi

if [ -n "$(git -C "$REFERENCE_TARGET" status --porcelain --untracked-files=all)" ]; then
    echo "Reference repository became dirty before audit." >&2
    exit 1
fi

python3 -B "$SCRIPT_DIR/check_parity_baseline.py" --integration-reference "$REFERENCE_TARGET"

POST_COMMIT=$(git -C "$REFERENCE_TARGET" rev-parse HEAD)
if [ "$POST_COMMIT" != "$REFERENCE_COMMIT" ]; then
    echo "Reference commit changed during audit: $POST_COMMIT" >&2
    exit 1
fi
if [ -n "$(git -C "$REFERENCE_TARGET" status --porcelain --untracked-files=all)" ]; then
    echo "Reference repository became dirty during audit." >&2
    exit 1
fi
