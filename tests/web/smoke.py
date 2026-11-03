#!/usr/bin/env python3
"""Browser smoke: serves a built browser app with the self-checking page
tests/web/smoke.html to headless Chromium, which posts its verdict back.

    python3 tests/web/smoke.py zig-out/web/browser-smoke [chromium]

Without a Chromium binary (argument, $CHROMIUM, or chromium, chromium-browser,
google-chrome on PATH) it reports that and exits 0, so that runners without
a browser still check the WebAssembly build.
"""
import functools
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading

here = os.path.dirname(os.path.abspath(__file__))


def find_browser(explicit):
    for name in [explicit, os.environ.get("CHROMIUM"), "chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]:
        if not name:
            continue
        path = shutil.which(name) or (name if os.path.isfile(name) else None)
        if path:
            return path
    return None


verdicts = []
reported = threading.Event()


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        verdicts.append(self.rfile.read(length).decode("utf-8", "replace"))
        self.send_response(204)
        self.end_headers()
        reported.set()

    def log_message(self, *args):
        pass


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    app = os.path.abspath(sys.argv[1])
    browser = find_browser(sys.argv[2] if len(sys.argv) > 2 else None)
    if not browser:
        print("smoke: no Chromium found; skipped the browser run")
        return 0
    with tempfile.TemporaryDirectory() as site:
        for name in ("app.wasm", "ziggurat.js"):
            shutil.copy(os.path.join(app, name), site)
        for name in ("smoke.html", "smoke.js"):
            shutil.copy(os.path.join(here, name), site)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=site))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = "http://127.0.0.1:%d/smoke.html" % server.server_address[1]
        with tempfile.TemporaryDirectory() as profile:
            command = [browser, "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run", "--user-data-dir=" + profile,
                       "--window-size=800,600", "--enable-logging=stderr", url]
            with tempfile.TemporaryFile("w+") as log:
                process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log)
                try:
                    reported.wait(90)
                finally:
                    process.kill()
                    process.wait()
                    server.shutdown()
                log.seek(0)
                errors = log.read()
    verdict = verdicts[0] if verdicts else "no verdict from the page in 90 seconds"
    print("smoke:", verdict)
    if verdict != "PASS":
        sys.stderr.write("\n".join(line for line in errors.splitlines() if "CONSOLE" in line or ":ERROR:" in line)[-4000:] + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
