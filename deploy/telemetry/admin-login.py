#!/usr/bin/env python3
"""Create a local-only magic login link without sending email or printing tokens."""
import argparse
import html
import http.cookies
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--email", required=True)
    parser.add_argument("--bootstrap", action="store_true", help="Create the owner and Duckpad app")
    args = parser.parse_args()
    os.chdir(Path(__file__).resolve().parent)
    if Path(".private/smtp.env").exists():
        print("SMTP is configured. Sign in through the dashboard to receive a login email.")
        return
    os.umask(0o077)
    private = Path(".private")
    private.mkdir(mode=0o700, exist_ok=True)
    base = "http://127.0.0.1:4318"
    public = "https://dp-stats.hongyoungjun.com"

    def post(path, data, cookie=None):
        headers = {"Content-Type": "application/json"}
        if cookie:
            headers["Cookie"] = cookie
        request = urllib.request.Request(base + path, json.dumps(data).encode(), headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    # No SMTP is configured: Aptabase writes the message to its private container log.
    path = "/api/_auth/register" if args.bootstrap else "/api/_auth/signin"
    post(path, {"email": args.email, "name": "Duckpad Admin"})
    logs = subprocess.check_output([
        "/opt/homebrew/bin/docker", "compose", "logs", "--since", "30s", "--no-color", "aptabase"
    ], text=True)
    links = re.findall(re.escape(public) + r'/api/_auth/continue\?token=[A-Za-z0-9_.-]+', logs)
    if not links:
        raise RuntimeError("No login link found. Check server configuration locally.")
    link = links[-1]

    if args.bootstrap:
        local = base + "/api/_auth/continue?" + urllib.parse.urlsplit(link).query
        try:
            response = urllib.request.build_opener(NoRedirect).open(local, timeout=15)
        except urllib.error.HTTPError as response:
            if response.code != 302:
                raise RuntimeError("Account activation failed") from None
            cookie_headers = response.headers.get_all("Set-Cookie", [])
        else:
            cookie_headers = response.headers.get_all("Set-Cookie", [])
        cookies = http.cookies.SimpleCookie()
        for header in cookie_headers:
            cookies.load(header)
        cookie = "; ".join(key + "=" + value.value for key, value in cookies.items())
        if not cookie:
            raise RuntimeError("Account activation did not return a session")
        request = urllib.request.Request(base + "/api/_apps", headers={"Cookie": cookie})
        with urllib.request.urlopen(request, timeout=15) as response:
            apps = json.load(response)
        app = next((app for app in apps if app["name"] == "Duckpad"), None)
        if app is None:
            app = post("/api/_apps", {"name": "Duckpad"}, cookie)
        Path("app-config.json").write_text(json.dumps({
            "host": public, "appKey": app["appKey"], "appId": app["id"]
        }, indent=2) + "\n")
        # Keep the bootstrap cookie out of the repository and terminal output.
        (private / "session-cookie.txt").write_text(cookie)
        post("/api/_auth/signin", {"email": args.email})
        logs = subprocess.check_output([
            "/opt/homebrew/bin/docker", "compose", "logs", "--since", "30s", "--no-color", "aptabase"
        ], text=True)
        link = re.findall(re.escape(public) + r'/api/_auth/continue\?token=[A-Za-z0-9_.-]+', logs)[-1]

    (private / "login.html").write_text(
        '<!doctype html><meta charset="utf-8"><title>Duckpad statistics login</title>'
        '<p><a rel="noreferrer" href="' + html.escape(link, quote=True) + '">Log in to Duckpad statistics</a></p>'
        '<p>This link expires. Run admin-login.py again to create a fresh link.</p>'
    )
    print("Login link saved to .private/login.html (owner access only).")
    if args.bootstrap:
        print("Duckpad app configuration saved to app-config.json.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # HTTP exceptions can contain authentication tokens in their URL.
        print("Setup failed: " + type(error).__name__ + ". Inspect configuration locally.")
        raise SystemExit(1)
