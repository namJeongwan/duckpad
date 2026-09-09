#!/usr/bin/env python3
"""Send quit events only to freshly launched, isolated Duckpad test processes.

Checks the normal, shutdown, restart and logout quit reasons without asking
loginwindow to shut down the machine. Each case relaunches the app to verify
unsaved scratch/file buffers and checks that the original file was not saved.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

SENDER = r'''
import AppKit
import Carbon
let pid = Int32(CommandLine.arguments[1])!
let reason = CommandLine.arguments[2]
let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
    targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
let reasons: [String: OSType] = ["shutdown": OSType(kAEShutDown), "restart": OSType(kAERestart), "logout": OSType(kAEReallyLogOut)]
if let code = reasons[reason] {
    event.setParam(NSAppleEventDescriptor(enumCode: code), forKeyword: AEKeyword(kAEQuitReason))
}
try event.sendEvent(options: [.noReply, .neverInteract], timeout: 5)
'''


def run_case(binary, sender, root, reason):
    case = root / reason
    case.mkdir()
    original = case / "source.txt"
    original.write_text("original on disk")
    env = {k: v for k, v in os.environ.items() if not k.startswith("DUCKPAD_")}
    env.update({
        "DUCKPAD_RECOVERY_ROOT": str(case / "Recovery"),
        "DUCKPAD_SETTINGS_FILE": str(case / "settings.json"),
        "DUCKPAD_DOCUMENT_BOOKMARKS_FILE": str(case / "bookmarks.json"),
        "DUCKPAD_WORKSPACE_ROOTS_FILE": str(case / "workspace.json"),
        "DUCKPAD_EXTENSIONS_ROOT": str(case / "Extensions"),
        "DUCKPAD_EXTENSION_POLICY_ROOT": str(case / "ExtensionPolicy"),
        "DUCKPAD_SESSION_QUIT_SMOKE_FILE": str(original),
    })
    log = case / "write.log"
    with log.open("w") as output:
        process = subprocess.Popen([str(binary)], env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 20
            while "Duckpad session quit smoke ready" not in log.read_text():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"{reason} never became ready: {log.read_text()}")
                time.sleep(0.05)
            # This PID is owned by this test; never broadcast a quit event.
            subprocess.run([str(sender), str(process.pid), reason], check=True, timeout=10)
            if process.wait(timeout=20) != 0:
                raise RuntimeError(f"{reason} exit failed: {log.read_text()}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    assert original.read_text() == "original on disk", f"{reason} overwrote original"
    env["DUCKPAD_SESSION_QUIT_SMOKE_VERIFY"] = "1"
    result = subprocess.run([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
    (case / "restore.log").write_text(result.stdout)
    assert result.returncode == 0, result.stdout
    assert "restored both dirty documents" in result.stdout, result.stdout
    assert original.read_text() == "original on disk"
    print(f"PASS: {reason}: no save/discard prompt; both dirty tabs restored; original unchanged", flush=True)


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/DuckpadApp").resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="duckpad-session-quit-"))
    print(f"Smoke artifacts: {root}", flush=True)
    source = root / "send-quit.swift"
    source.write_text(SENDER)
    sender = root / "send-quit"
    subprocess.run(["swiftc", str(source), "-o", str(sender)], check=True, timeout=60)
    for reason in ("quit", "shutdown", "restart", "logout"):
        run_case(binary, sender, root, reason)


if __name__ == "__main__":
    main()
