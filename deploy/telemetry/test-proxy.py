#!/usr/bin/env python3
"""Exercise the real nginx rules against a fake upstream; never send login email."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker", default="/opt/homebrew/bin/docker")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    image = next(line.split("=", 1)[1] for line in (root / ".env.example").read_text().splitlines()
                 if line.startswith("NGINX_IMAGE="))
    name = "dp-telemetry-proxy-test-" + uuid.uuid4().hex[:10]
    app, proxy = name + "-app", name + "-proxy"

    def docker(*arguments, check=True):
        return subprocess.run([args.docker, *arguments], check=check, capture_output=True, text=True)

    private = root / ".private"
    private.mkdir(mode=0o700, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="proxy-test-", dir=private) as directory:
        fixture = Path(directory) / "fake.conf"
        fixture.write_text('server { listen 8080; access_log off; location / { '
            'add_header X-Seen-Identity "$http_cf_connecting_ip|$http_x_real_ip|$http_cookie|$http_forwarded|$http_cf_ipcountry|$http_cloudfront_viewer_address"; '
            'add_header X-Seen-Forwarded $http_x_forwarded_for; '
            'add_header X-Seen-Key $http_app_key; '
            'add_header X-Seen-Agent $http_user_agent; return 204; } }\n')
        config = Path(directory) / "proxy.conf"
        config.write_bytes((root / "nginx.conf").read_bytes())
        try:
            docker("network", "create", name)
            docker("run", "-d", "--name", app, "--network", name, "--network-alias", "aptabase",
                   "-v", str(fixture) + ":/etc/nginx/conf.d/default.conf:ro", image)
            docker("run", "-d", "--name", proxy, "--network", name, "-p", "127.0.0.1::80",
                   "-v", str(config) + ":/etc/nginx/conf.d/default.conf:ro", image)
            address = docker("port", proxy, "80/tcp").stdout.strip()

            def request(path, ip="203.0.113.10", method="POST"):
                req = urllib.request.Request("http://" + address + path,
                    data=b"{}" if method == "POST" else None, method=method,
                    headers={"CF-Connecting-IP": ip, "Content-Type": "application/json"})
                try:
                    with urllib.request.urlopen(req, timeout=3) as response:
                        return response.status
                except urllib.error.HTTPError as error:
                    return error.code

            for _ in range(30):
                try:
                    if request("/", method="GET") == 204:
                        break
                except OSError:
                    pass
                time.sleep(0.2)
            else:
                raise AssertionError("Isolated proxy did not become ready")
            for path in ["/api/_auth/register", "/API/_AUTH/REGISTER/"]:
                assert request(path) == 403, "Public registration must be blocked"
            assert request("/api/_auth/signin", method="GET") == 403
            paths = ["/api/_auth/signin", "/API/_AUTH/SIGNIN/"]
            same_ip = [request(paths[i % 2]) for i in range(8)]
            assert same_ip[0] == 204, "Normal signin must reach the upstream"
            assert same_ip.count(204) <= 3 and 429 in same_ip, "Signin IP bound missing"
            distinct_ips = [request(paths[i % 2], ip="203.0.113." + str(40 + i)) for i in range(12)]
            assert 429 in distinct_ips and distinct_ips.count(204) <= 5, "Global mail bound missing"
            assert request("/api/v0/events", ip="203.0.113.200") == 204
            assert request("/api/v0/event", ip="203.0.113.200") == 204
            assert request("/api/_auth/continue?token=fixture", method="GET") == 204
            for endpoint in ["/api/v0/events", "/API/V0/EVENT/"]:
                req = urllib.request.Request("http://" + address + endpoint, data=b"{}", headers={
                    "CF-Connecting-IP": "203.0.113.200", "X-Real-IP": "203.0.113.201",
                    "X-Forwarded-For": "203.0.113.202", "CloudFront-Viewer-Address": "203.0.113.203:5000",
                    "Forwarded": "for=203.0.113.204", "Cookie": "identity=private",
                    "CF-IPCountry": "KR", "User-Agent": "private-device", "App-Key": "public-test-key",
                })
                with urllib.request.urlopen(req, timeout=3) as response:
                    assert response.headers["X-Seen-Identity"] == "|||||", "Identity header forwarded"
                    assert response.headers["X-Seen-Forwarded"] == "127.0.0.1"
                    assert response.headers["X-Seen-Key"] == "public-test-key"
                    assert response.headers["X-Seen-Agent"] == "Duckpad-Usage/1"
            print("PASS: registration denied; signin IP/global bounds return 429; ingestion headers anonymized; login continuation reachable")
        finally:
            docker("rm", "-f", proxy, app, check=False)
            docker("network", "rm", name, check=False)


if __name__ == "__main__":
    main()
