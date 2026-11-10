"""Loopback servers for the HTTP sign-in and certificate error smoke.

An HTTP server asks for Basic credentials in two realms, an HTTPS server
presents the public, disposable fixture certificate that nothing trusts, and a
second HTTPS server with that certificate requires a client certificate
(mutual TLS). The smoke runs with the origins and the certificate's path; its
exit code is the host's, and the host checks what the servers saw.
"""
import argparse
import base64
import pathlib
import socket
import ssl
import subprocess
import sys
import threading

CREDENTIALS = "Basic " + base64.b64encode(b"ziggurat:s3cret").decode()


class Server:
    def __init__(self, context=None):
        self.context = context
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(16)
        scheme = "https" if context else "http"
        self.origin = "%s://127.0.0.1:%d" % (scheme, self.listener.getsockname()[1])
        self.lock = threading.Lock()
        self.seen = []
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        while True:
            connection, _ = self.listener.accept()
            # Each connection on its own thread: an engine keeps idle ones open.
            threading.Thread(target=self.connection, args=(connection,), daemon=True).start()

    def connection(self, connection):
        connection.settimeout(10)
        try:
            stream = self.context.wrap_socket(connection, server_side=True) if self.context else connection
            with stream:
                while self.serve(stream):
                    pass
        except (OSError, ssl.SSLError):
            # A client that rejects the certificate closes before any HTTP.
            connection.close()

    def serve(self, stream):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = stream.recv(8192)
            if not chunk:
                return False
            data += chunk
            if len(data) > 65536:
                return False
        head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
        path = head[0].split(" ")[1]
        headers = {line.split(":", 1)[0].strip().lower(): line.split(":", 1)[1].strip() for line in head[1:] if ":" in line}
        authorized = headers.get("authorization") == CREDENTIALS
        with self.lock:
            self.seen.append((path, authorized))
        status, extra, body = "200 OK", "", "<!doctype html><title>trusted</title>"
        if not self.context and path != "/favicon.ico":
            realm = "elsewhere" if path.startswith("/deny") else "ziggurat test"
            if authorized and realm == "ziggurat test":
                body = "<!doctype html><title>welcome</title>"
            else:
                status, extra, body = "401 Unauthorized", 'WWW-Authenticate: Basic realm="%s"\r\n' % realm, "<!doctype html><title>denied</title>"
        payload = body.encode()
        stream.sendall(("HTTP/1.1 %s\r\n%sContent-Type: text/html\r\nContent-Length: %d\r\nCache-Control: no-store\r\n\r\n" % (status, extra, len(payload))).encode() + payload)
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True)
    parser.add_argument("--extension", help="Linux: the request-policy extension's directory")
    arguments = parser.parse_args()
    fixtures = pathlib.Path(__file__).resolve().parent / "fixtures" / "profile-https"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(fixtures / "server-cert.pem", fixtures / "server-key.pem")
    mutual_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    mutual_context.load_cert_chain(fixtures / "server-cert.pem", fixtures / "server-key.pem")
    # Only a certificate this fixture CA issued would pass; the smoke refuses
    # to give any, so no request ever gets through.
    mutual_context.load_verify_locations(fixtures / "other-cert.pem")
    mutual_context.verify_mode = ssl.CERT_REQUIRED
    plain, secure, mutual = Server(), Server(context), Server(mutual_context)
    try:
        command = [arguments.exe, plain.origin, secure.origin, str(fixtures / "server-cert.pem"), mutual.origin]
        if arguments.extension:
            command.append(str(pathlib.Path(arguments.extension).resolve()))
        code = subprocess.run(command, timeout=120).returncode
    except subprocess.TimeoutExpired:
        print("http auth smoke timed out", file=sys.stderr)
        return 1
    if code != 0:
        with plain.lock, secure.lock, mutual.lock:
            print("http auth smoke failed; HTTP saw %r, HTTPS saw %r, mutual TLS saw %r" % (plain.seen, secure.seen, mutual.seen), file=sys.stderr)
        return code
    with plain.lock, secure.lock, mutual.lock:
        if mutual.seen:
            print("a request got through mutual TLS without a client certificate: %r" % mutual.seen, file=sys.stderr)
            return 1
        if not any(path == "/private" and authorized for path, authorized in plain.seen):
            print("the server never saw the credentials: %r" % plain.seen, file=sys.stderr)
            return 1
        if not any(path == "/tls" for path, _ in secure.seen):
            print("the HTTPS page was never requested over TLS: %r" % secure.seen, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
