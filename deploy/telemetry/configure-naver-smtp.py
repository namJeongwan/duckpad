#!/usr/bin/env python3
"""Configure Naver SMTP using a hidden terminal prompt; never send a test email."""
import argparse
import getpass
import os
from pathlib import Path
import re
import smtplib
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--username", required=True, help="Naver ID or @naver.com email address")
    args = parser.parse_args()
    identity = re.fullmatch(r"([a-zA-Z0-9_-]+)(?:@naver\.com)?", args.username.strip(), flags=re.IGNORECASE)
    if not identity:
        parser.error("Use a Naver ID or an @naver.com email address.")
    args.username = identity.group(1).lower()
    if not sys.stdin.isatty():
        print("Run interactively with ssh -t; the password must not be passed as an argument.")
        return 1
    os.chdir(Path(__file__).resolve().parent)
    os.umask(0o077)
    compose = ["/opt/homebrew/bin/docker", "compose"]
    subprocess.run(compose + ["config", "--quiet"], check=True)
    print("Use an application password issued for this Naver ID, not the normal account password.")
    password = getpass.getpass("Naver application password (hidden): ").strip()
    if not password or any(ch in password for ch in "\r\n\x00"):
        raise ValueError("Invalid password input")
    # Check credentials over verified TLS before changing the running service.
    with smtplib.SMTP_SSL("smtp.naver.com", 465, context=ssl.create_default_context(), timeout=10) as smtp:
        smtp.login(args.username, password)
    private = Path(".private")
    private.mkdir(mode=0o700, exist_ok=True)
    private.chmod(0o700)
    values = {
        "SMTP_HOST": "smtp.naver.com",
        "SMTP_PORT": "465",
        "SMTP_USERNAME": args.username,
        "SMTP_PASSWORD": password,
        "SMTP_FROM_ADDRESS": args.username + "@naver.com",
    }
    fd, temporary = tempfile.mkstemp(prefix="smtp-", dir=private)
    try:
        with os.fdopen(fd, "w") as output:
            output.write("".join(key + "=" + value + "\n" for key, value in values.items()))
        # Compose's raw env_file format keeps $, quotes and backslashes literal.
        os.replace(temporary, private / "smtp.env")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    subprocess.run(compose + ["config", "--quiet"], check=True)
    subprocess.run(compose + ["up", "-d", "--no-deps", "--force-recreate", "aptabase"], check=True)
    for attempt in range(30):
        try:
            with urllib.request.urlopen("http://127.0.0.1:4318/healthz", timeout=2) as response:
                if response.status == 200:
                    break
        except OSError:
            pass
        time.sleep(1)
    else:
        raise RuntimeError("Health check timed out")
    # The recreated application's container IP may have changed.
    subprocess.run(compose + ["exec", "-T", "proxy", "nginx", "-s", "reload"], check=True)
    print("SMTP configured. No email was sent by this script.")
    print("Open https://dp-stats.hongyoungjun.com and sign in with your existing administrator email.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except smtplib.SMTPAuthenticationError as error:
        print("Naver rejected SMTP authentication (SMTP code " + str(error.smtp_code) + ").")
        print("Check that POP3/SMTP is enabled and enter a newly issued application password for the specified Naver ID.")
        print("No SMTP configuration was changed. Do not share the password in chat.")
        raise SystemExit(1)
    except Exception as error:
        # Never print server responses, credentials, or expanded Compose config.
        print("SMTP setup failed: " + type(error).__name__ + ". Check credentials and server status locally.")
        raise SystemExit(1)
