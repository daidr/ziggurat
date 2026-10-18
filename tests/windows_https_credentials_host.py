"""Explicit, bounded TLS wire oracle for the Windows credential smoke object.

Only the test adapter trusts the pinned public fixture certificate. This host
does not install a certificate or alter the machine, SDK, or browser settings.
"""
import argparse
import collections
import json
import pathlib
import re
import shutil
import socket
import ssl
import subprocess
import threading


class Host:
    def __init__(self, number, certificate, key, records, lock, failures):
        self.number, self.records, self.lock, self.failures = number, records, lock, failures
        self.details = []
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(certificate, key)
        self.listener = socket.socket()
        try:
            self.listener.bind(("127.0.0.1", 0))
            self.listener.listen(16)
            self.origin = "https://127.0.0.1:%d" % self.listener.getsockname()[1]
            self.stopping = threading.Event()
            self.thread = threading.Thread(target=self.run, name="credential-tls-%d" % number)
            self.started = False
            self.origins = None
        except BaseException:
            self.listener.close()
            raise

    def start(self):
        self.thread.start()
        self.started = True

    def run(self):
        while True:
            connection, _ = self.listener.accept()
            if self.stopping.is_set():
                connection.close()
                return
            connection.settimeout(5)
            try:
                with self.context.wrap_socket(connection, server_side=True) as stream:
                    self.serve(stream)
            except (ssl.SSLError, ConnectionResetError, ConnectionAbortedError, BrokenPipeError, TimeoutError):
                # Certificate rejection deliberately closes before any HTTP.
                connection.close()
            except Exception as error:
                connection.close()
                with self.lock:
                    self.failures.append(type(error).__name__)

    def stop(self):
        try:
            if self.started:
                self.stopping.set()
                with socket.create_connection(self.listener.getsockname(), timeout=5):
                    pass
                self.thread.join(7)
                if self.thread.is_alive():
                    raise AssertionError("TLS host did not stop")
        finally:
            self.listener.close()

    def serve(self, stream):
        request = bytearray()
        while b"\r\n\r\n" not in request:
            part = stream.recv(4096)
            if not part:
                return
            request.extend(part)
            if len(request) > 16384:
                raise AssertionError("request exceeds oracle bound")
        lines = request.decode("ascii").split("\r\n")
        method, path, _ = lines[0].split(" ")
        headers = {}
        for line in lines[1:]:
            if not line:
                break
            name, value = line.split(":", 1)
            name = name.lower()
            if name in headers:
                raise AssertionError("duplicate request header")
            headers[name] = value.strip()
        value = headers.get("authorization", "")
        kind = 0 if not value else 1 if value == "Bearer " + "5a" * 32 else 2 if value == "Bearer " + "6b" * 32 else 3
        with self.lock:
            if len(self.records) >= 256:
                raise AssertionError("wire oracle exceeds bound")
            self.records.append((self.number, path, method, kind))
            self.details.append({"origin": self.number, "path": path, "method": method, "authorization": kind,
                                 "request_origin": headers.get("origin"),
                                 "preflight_method": headers.get("access-control-request-method"),
                                 "preflight_headers": headers.get("access-control-request-headers")})
        status, content_type, body, location = self.response(path)
        output = ["HTTP/1.1 %s" % status, "Connection: close", "Cache-Control: no-store", "Content-Type: " + content_type,
                  "Content-Length: %d" % len(body)]
        if location:
            output.append("Location: " + location)
        # Some native redirect requests carry no Origin. The test's fetch uses
        # default same-origin credentials, so an absent-Origin cross-origin
        # response can use '*'; an actual Origin (including 'null') is reflected.
        output += ["Access-Control-Allow-Origin: " + headers.get("origin", "*"), "Access-Control-Allow-Credentials: true",
                   "Access-Control-Allow-Methods: GET, HEAD", "Access-Control-Allow-Headers: Authorization"]
        stream.sendall(("\r\n".join(output) + "\r\n\r\n").encode("ascii"))
        if method != "HEAD":
            stream.sendall(body)

    def response(self, path):
        prefix, _, route = path.strip("/").partition("/")
        own, peer, forbidden, _ = self.origins
        location = None
        if route == "top":
            location = peer + "/" + prefix + "/doc-back"
        elif route == "doc-back":
            location = own + "/" + prefix + "/start"
        elif route == "same":
            location = own + "/" + prefix + "/end"
        elif route == "peer":
            location = peer + "/" + prefix + "/back"
        elif route == "back":
            location = own + "/" + prefix + "/end"
        elif route == "blocked":
            location = forbidden + "/" + prefix + "/leak"
        if location:
            return "302 Found", "text/plain", b"", location
        if route == "start":
            body = ('<!doctype html><title>credential test</title><link rel="icon" href="data:,">'
                    '<script src="/%s/boot.js"></script>' % prefix).encode("ascii")
            return "200 OK", "text/html", body, None
        if route == "boot.js":
            script = """(async()=>{
                const p=PREFIX;
                for(const [path,options] of [['get',{}],['head',{method:'HEAD'}],['same',{}],['peer',{}]]){
                    const r=await fetch('/'+p+'/'+path,options);if(!r.ok)throw Error(path);
                }
                if(!(await fetch(PEER+'/'+p+'/public')).ok)throw Error('public');
                if(p!=='n'&&!(await fetch('/'+p+'/spoof',{headers:{Authorization:'page-owned-value'}})).ok)throw Error('spoof');
                const denied=await fetch('/'+p+'/blocked').then(r=>!r.ok,()=>true);
                if(!denied)throw Error('unlisted redirect escaped');
                chrome.webview.postMessage('ready-'+p);
            })().catch(()=>chrome.webview.postMessage('fixture-failed'));
            """.replace("PREFIX", json.dumps(prefix)).replace("PEER", json.dumps(peer))
            return "200 OK", "text/javascript", script.encode("ascii"), None
        return "200 OK", "text/plain", b"asset-ok", None


def validate(mode, wire, callbacks):
    sent = collections.Counter(wire)
    observed = collections.Counter(callbacks)
    for record, count in sent.items():
        if count > observed[record]:
            raise AssertionError("wire request bypassed callback decoration: %r" % (record,))
    for origin, path, method, authorization in wire:
        if origin in (2, 3) or method not in ("GET", "HEAD"):
            raise AssertionError("forbidden request escaped: %r" % ((origin, path, method, authorization),))
        expected = 0 if origin == 1 or path.startswith("/n/") else 1 if path.startswith("/a/") else 2
        if authorization != expected:
            raise AssertionError("wire Authorization mismatch: %r" % ((origin, path, method, authorization),))
    if mode == "exercise":
        expected_prefixes = {"a": 1, "b": 2, "n": 2}
        for prefix, runs in expected_prefixes.items():
            auth = 0 if prefix == "n" else 1 if prefix == "a" else 2
            for origin, route, method, value, multiplier in [
                (0, "top", "GET", auth, 1), (1, "doc-back", "GET", 0, 1),
                (0, "start", "GET", auth, 1), (0, "boot.js", "GET", auth, 1),
                (0, "get", "GET", auth, 1), (0, "head", "HEAD", auth, 1),
                (0, "same", "GET", auth, 1), (0, "peer", "GET", auth, 1),
                (1, "back", "GET", 0, 1), (0, "end", "GET", auth, 2),
                (1, "public", "GET", 0, 1), (0, "blocked", "GET", auth, 1),
            ]:
                if sent[(origin, "/" + prefix + "/" + route, method, value)] != runs * multiplier:
                    raise AssertionError("missing route or incorrect stage count: %s/%s" % (prefix, route))
            if prefix != "n" and sent[(0, "/" + prefix + "/spoof", "GET", auth)] != runs:
                raise AssertionError("page header override not proven")
    elif mode == "redirect_denied":
        if wire != [(0, "/a/top", "GET", 1)]:
            raise AssertionError("denied navigation followed redirect")
    elif wire:
        raise AssertionError("negative mode sent HTTP")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=pathlib.Path)
    parser.add_argument("--cache", required=True, type=pathlib.Path)
    parser.add_argument("--log", required=True, type=pathlib.Path)
    parser.add_argument("--mode", choices=("exercise", "redirect_denied", "close_ready", "wrong_certificate"))
    args = parser.parse_args()
    fixtures = pathlib.Path(__file__).resolve().parent / "fixtures" / "profile-https"
    args.cache.mkdir(parents=True, exist_ok=True)
    cache_root = args.cache.resolve(strict=True)
    args.log.parent.mkdir(parents=True, exist_ok=True)
    results = []
    for mode in ([args.mode] if args.mode else ["exercise", "redirect_denied", "close_ready", "wrong_certificate"]):
        basename = "windows-credentials-" + mode
        directory = cache_root / basename
        if directory.exists():
            raise AssertionError("private fixture directory already exists; inspect before reuse: " + str(directory))
        directory.mkdir()
        profiles = [directory / "profile-a", directory / "profile-b"]
        for profile in profiles:
            profile.mkdir()
        wire, failures, lock = [], [], threading.Lock()
        hosts = []
        try:
            for i in range(4):
                hosts.append(Host(i, fixtures / ("other-cert.pem" if i == 3 else "server-cert.pem"),
                                  fixtures / ("other-key.pem" if i == 3 else "server-key.pem"), wire, lock, failures))
            origins = [host.origin for host in hosts]
            for host in hosts:
                host.origins = origins
                host.start()
            try:
                process = subprocess.run([str(args.exe.resolve()), mode, *origins, *map(str, profiles)],
                                         capture_output=True, text=True, timeout=60)
                returncode, output = process.returncode, process.stdout + process.stderr
            except subprocess.TimeoutExpired as error:
                def text(value):
                    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
                returncode, output = 124, text(error.stdout) + text(error.stderr) + "native credential driver timed out\n"
        finally:
            for host in hosts:
                try:
                    host.stop()
                except Exception as error:
                    failures.append("host shutdown: " + type(error).__name__)
        print(output, end="")
        callbacks = [(int(origin), path, ("GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS")[int(method)], int(auth))
                     for origin, path, method, auth in re.findall(r"request_oracle origin=(\d+) path=(\S+) method=(\d+) auth=(\d+)", output)]
        results.append({"mode": mode, "returncode": returncode, "wire": wire, "callbacks": callbacks,
                        "request_details": [detail for host in hosts for detail in host.details],
                        "host_failures": failures, "output": output})
        args.log.write_text(json.dumps(results, indent=2), encoding="utf-8")
        if returncode or failures or "credential_probe_shutdown=confirmed" not in output:
            raise AssertionError("native credential smoke failed; private profile retained")
        validate(mode, wire, callbacks)
        # The child has waited for every private browser process and released all
        # native references. Delete only this exact, newly created fixture path.
        if directory.is_symlink() or directory.is_junction():
            raise AssertionError("private fixture directory became a link")
        resolved = directory.resolve(strict=True)
        if resolved.parent != cache_root or resolved.name != basename:
            raise AssertionError("private fixture directory escaped its exact cache root")
        shutil.rmtree(resolved)
        print("windows credential wire oracle mode=%s requests=%d callbacks=%d passed" % (mode, len(wire), len(callbacks)))


if __name__ == "__main__":
    main()
