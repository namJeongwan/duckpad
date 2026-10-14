#!/usr/bin/env python3
"""Reproducible native input/draw maximum gates; isolated generated documents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TARGET_BYTES = 9_184_692
FIXTURES = {
    "json": ("json", '{"name":"payload","n":42,"ok":true},'),
    "javascript": ("cpp", "function f(x){return x+1;}const a=f(42);"),
    "css": ("css", ".item{color:red;padding:4px;margin:0;display:block;}"),
    "xml": ("xml", '<item id="123"><name>payload</name><value>42</value></item>'),
    "plain": ("null", "event payload abcdefghijklmnopqrstuvwxyz 0123456789 "),
    "korean": ("null", "한글 입력 성능 확인 가나다라마바 사아자차카타파하 "),
    "tabs": ("null", "payload\t1234\tvalue\t"),
    "emoji": ("null", "🦆🌍🚀 🎉✨🙂 "),
    "combining": ("null", "éäñ 각 "),
    "log": ("null", "2026-10-14 INFO request completed id=42 duration_ms=10 payload=abcdefgh\n"),
    "multiline-javascript": ("cpp", "function f(x){\n  return x+1;\n}\nconst a=f(42);\n"),
    "multiline-css": ("css", ".item {\n  color: red;\n  padding: 4px;\n}\n"),
    "multiline-xml": ("xml", '<item id="123">\n  <name>payload</name>\n  <value>42</value>\n</item>\n'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cases", default=",".join(FIXTURES))
    parser.add_argument("--positions", default="start")
    parser.add_argument("--style-state", choices=["settled", "pending", "recoloured"], default="settled")
    parser.add_argument("--json-fixture", type=Path, help="Optional additional JSON, read only")
    args = parser.parse_args()
    cases = args.cases.split(",")
    if any(case not in FIXTURES for case in cases):
        parser.error("Unknown fixture name")
    positions = args.positions.split(",")
    if any(position not in ["start", "quarter", "middle", "three-quarters", "long-string", "end"] for position in positions):
        parser.error("Unknown first-input position")
    out = (args.output or Path(tempfile.mkdtemp(prefix="duckpad-long-line-"))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not args.skip_build:
        subprocess.run(["swift", "build", "-c", "release", "--product", "DuckpadPerformanceBenchmark"], cwd=ROOT, check=True)
    binary_dir = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip()
    inputs = []
    for name in cases:
        lexer, unit = FIXTURES[name]
        raw = unit.encode()
        data = raw * (TARGET_BYTES // len(raw))
        if name == "json":
            data = b"[" + data[:-1] + b"]"
        elif name == "xml":
            data = b"<root>" + data + b"</root>"
        path = out / (name + ".txt")
        path.write_bytes(data)
        inputs.append((name, path, lexer))
    if args.json_fixture:
        inputs.append(("provided-json", args.json_fixture.resolve(), "json"))
    results = []
    for name, path, lexer in inputs:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        for position in positions:
            log_path = out / f"{name}-{position}.log"
            env = {**os.environ, "DUCKPAD_LONG_LINE_FIRST_POSITION": position,
                   "DUCKPAD_LONG_LINE_STYLE_STATE": args.style_state}
            if args.quick:
                env["DUCKPAD_LONG_LINE_QUICK"] = "1"
            else:
                env.pop("DUCKPAD_LONG_LINE_QUICK", None)
            with log_path.open("w") as log:
                process = subprocess.run([str(Path(binary_dir) / "DuckpadPerformanceBenchmark"), "--long-line", str(path), lexer],
                                         cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            output = log_path.read_text()
            style_stalls = [float(value) for value in re.findall(r"max_main_stall_ms=([\d.]+)", output)]
            samples = re.findall(r"operation=(\S+) samples=(\d+).*?max_ms=([\d.]+).*?pass=(\w+)", output)
            result = {"fixture": name, "lexer": lexer, "bytes": path.stat().st_size, "sha256": digest,
                      "first_position": position, "events": sum(int(count) for op, count, _max, _passed in samples if op != "idle-turn"),
                      "max_ms": max([float(value) for _op, _count, value, _passed in samples] + style_stalls, default=None),
                      "style_main_stall_ms": max(style_stalls, default=None),
                      "passed": process.returncode == 0 and len(samples) == 48 and "undo_redo_exact=true" in output,
                      "log": log_path.name}
            results.append(result)
            print(json.dumps(result), flush=True)
    report = {"platform": platform.platform(), "machine": platform.machine(), "budget_ms": 50,
              "quick": args.quick, "style_state": args.style_state, "results": results}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Report: {out / 'report.json'}", flush=True)
    return 0 if all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
