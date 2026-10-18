"""Bounded TLS and wire oracle for the explicit document-initializer driver.

The native test adapter alone trusts the existing fixture certificate. The
host owns its four listeners and one newly created private Profile per mode.
"""
import argparse
import collections
import json
import pathlib
import re
import shutil
import subprocess
import threading

from windows_https_credentials_host import Host


MODES = ("exercise", "close_pending", "stop_pending", "wrong_certificate")
METHODS = ("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS")


class InitializerHost(Host):
    def response(self, path):
        # The snapshot is taken before the page's own script can change it.
        # A no-src child checks top-frame/about:blank exclusion. The explicit
        # Function attempt is a CSP negative control, never script execution
        # machinery for the framework or fixture.
        body = b"""<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-fixture'; frame-src 'self'; base-uri 'none'; object-src 'none'">
<title>document initializer fixture</title><link rel="icon" href="data:,">
<body><script nonce="fixture">
(()=>{
    try {
        const snapshot=Array.isArray(window.__zigInitializer)?window.__zigInitializer.slice():[];
        let csp=false;
        try { new Function('return 1')(); } catch (_) { csp=true; }
        const child=document.createElement('iframe');
        child.addEventListener('load',()=>{
            try {
                const frame=child.contentWindow.location.href==='about:blank' &&
                    typeof child.contentWindow.__zigInitializer==='undefined';
                chrome.webview.postMessage(JSON.stringify({path:location.pathname,
                    origin:location.origin,trace:snapshot,frame,csp}));
            } catch (_) { chrome.webview.postMessage('fixture-failed'); }
        },{once:true});
        document.body.appendChild(child);
    } catch (_) { chrome.webview.postMessage('fixture-failed'); }
})();
</script>"""
        return "200 OK", "text/html; charset=utf-8", body, None


def validate(mode, wire, callbacks):
    sent, observed = collections.Counter(wire), collections.Counter(callbacks)
    for record, count in sent.items():
        if count > observed[record]:
            raise AssertionError("wire request bypassed the native observer: %r" % (record,))
    for record in wire:
        origin, _, method, authorization = record
        if origin not in (0, 1) or method != "GET" or authorization != 0:
            raise AssertionError("unexpected document request: %r" % (record,))
    if mode == "exercise":
        expected = collections.Counter({
            (0, "/a/start", "GET", 0): 2,
            (1, "/peer/start", "GET", 0): 1,
            (0, "/throw/start", "GET", 0): 3,
            (0, "/empty/start", "GET", 0): 1,
            (0, "/guard-reset/start", "GET", 0): 1,
        })
    elif mode in ("close_pending", "stop_pending"):
        expected = collections.Counter({(0, "/a/start", "GET", 0): 1})
    else:
        expected = collections.Counter()
    if sent != expected:
        raise AssertionError("incorrect document wire counts: expected=%r actual=%r" % (expected, sent))


def output_text(value):
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=pathlib.Path)
    parser.add_argument("--cache", required=True, type=pathlib.Path)
    parser.add_argument("--log", required=True, type=pathlib.Path)
    parser.add_argument("--mode", choices=MODES)
    args = parser.parse_args()
    fixtures = pathlib.Path(__file__).resolve().parent / "fixtures" / "profile-https"
    args.cache.mkdir(parents=True, exist_ok=True)
    cache_root = args.cache.resolve(strict=True)
    args.log.parent.mkdir(parents=True, exist_ok=True)
    results = []
    for mode in ([args.mode] if args.mode else MODES):
        basename = "windows-initializers-" + mode
        directory = cache_root / basename
        profile = directory / "profile"
        wire, failures, lock, hosts = [], [], threading.Lock(), []
        returncode, output = 127, "native initializer driver did not start\n"
        try:
            if directory.exists() or directory.is_symlink() or directory.is_junction():
                raise AssertionError("private fixture already exists; inspect before reuse: " + str(directory))
            directory.mkdir()
            profile.mkdir()
            for number in range(4):
                hosts.append(InitializerHost(number,
                    fixtures / ("other-cert.pem" if number == 3 else "server-cert.pem"),
                    fixtures / ("other-key.pem" if number == 3 else "server-key.pem"),
                    wire, lock, failures))
            origins = [host.origin for host in hosts]
            for host in hosts:
                host.origins = origins
                host.start()
            try:
                process = subprocess.run([str(args.exe.resolve()), mode, *origins, str(profile)],
                    capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
                returncode, output = process.returncode, process.stdout + process.stderr
            except subprocess.TimeoutExpired as error:
                returncode = 124
                output = output_text(error.stdout) + output_text(error.stderr) + "native initializer driver timed out\n"
        except Exception as error:
            failures.append("setup/driver: " + type(error).__name__)
        finally:
            for host in hosts:
                try:
                    host.stop()
                except Exception as error:
                    failures.append("host shutdown: " + type(error).__name__)
        print(output, end="")
        callbacks = []
        for origin, path, method, authorization in re.findall(
                r"request_oracle origin=(\d+) path=(\S+) method=(\d+) auth=(\d+)", output):
            index = int(method)
            if index >= len(METHODS):
                failures.append("invalid callback method")
                continue
            callbacks.append((int(origin), path, METHODS[index], int(authorization)))
        results.append({"mode": mode, "returncode": returncode, "wire": wire, "callbacks": callbacks,
            "request_details": [detail for host in hosts for detail in host.details],
            "host_failures": failures, "output": output})
        args.log.write_text(json.dumps(results, indent=2), encoding="utf-8")
        if returncode or failures or "initializer_probe_shutdown=confirmed" not in output:
            raise AssertionError("native initializer smoke failed; private Profile retained")
        validate(mode, wire, callbacks)
        # Only this exact newly created directory may be removed, after the
        # driver has waited for its browser handles and all native references.
        if directory.is_symlink() or directory.is_junction():
            raise AssertionError("private fixture directory became a link")
        resolved = directory.resolve(strict=True)
        if resolved.parent != cache_root or resolved.name != basename:
            raise AssertionError("private fixture escaped its exact cache root")
        shutil.rmtree(resolved)
        print("windows initializer wire oracle mode=%s requests=%d callbacks=%d passed" %
            (mode, len(wire), len(callbacks)))


if __name__ == "__main__":
    main()
