#!/usr/bin/env python3
"""Install Duckpad's repository-local raw-commit blocker."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from review_common import ReviewError, git_output, git_root


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        repo = git_root(args.repo)
        hook = repo / "scripts/review/hooks/pre-commit"
        if not hook.is_file():
            raise ReviewError(f"hook source missing: {hook}")
        hook.chmod(0o755)
        git_output(repo, "config", "--local", "core.hooksPath", "scripts/review/hooks")
        print("Installed Phase-0 raw-commit blocker in local Git config")
        return 0
    except (ReviewError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
