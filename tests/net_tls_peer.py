"""Loopback HTTPS/WSS peer for the network client TLS probe (Python 3.10+).

Serves one plain HTTPS response and one WebSocket echo session over TLS on
127.0.0.1 with a disposable certificate created by the calling script. Prints
the port on its first line, then exits after the expected connections.
"""
import argparse
import base64
import hashlib
import socket
import ssl
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BODY = b"z" * 100_000


def read_exact(conn, state, count):
    while len(state["buffer"]) < count:
        chunk = conn.recv(65536)
        if not chunk:
            raise EOFError("peer closed")
        state["buffer"] += chunk
    data, state["buffer"] = state["buffer"][:count], state["buffer"][count:]
    return data


def frame(opcode, payload):
    size = len(payload)
    if size < 126:
        header = bytes([0x80 | opcode, size])
    elif size < 65536:
        header = bytes([0x80 | opcode, 126]) + size.to_bytes(2, "big")
    else:
        header = bytes([0x80 | opcode, 127]) + size.to_bytes(8, "big")
    return header + payload


def echo(conn, state):
    while True:
        header = read_exact(conn, state, 2)
        opcode, size = header[0] & 0x0F, header[1] & 0x7F
        if not header[1] & 0x80:
            raise ValueError("client frame without mask")
        if size == 126:
            size = int.from_bytes(read_exact(conn, state, 2), "big")
        elif size == 127:
            size = int.from_bytes(read_exact(conn, state, 8), "big")
        mask = read_exact(conn, state, 4)
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read_exact(conn, state, size)))
        if opcode == 0x8:
            conn.sendall(frame(0x8, payload))
            return
        conn.sendall(frame(opcode, payload))


def handle(raw, context):
    with context.wrap_socket(raw, server_side=True) as conn:
        state = {"buffer": b""}
        while b"\r\n\r\n" not in state["buffer"]:
            chunk = conn.recv(4096)
            if not chunk:
                return
            state["buffer"] += chunk
        head, state["buffer"] = state["buffer"].split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        headers = {name.strip().lower(): value.strip() for name, value in (line.split(":", 1) for line in lines[1:])}
        if headers.get("upgrade", "").lower() == "websocket":
            digest = hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()
            accept = base64.b64encode(digest).decode()
            conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            echo(conn, state)
        else:
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(BODY) + BODY)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cert")
    parser.add_argument("key")
    parser.add_argument("--connections", type=int, default=3)
    args = parser.parse_args()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(4)
        print(listener.getsockname()[1], flush=True)
        threads = []
        for _ in range(args.connections):
            raw, _ = listener.accept()
            thread = threading.Thread(target=lambda r=raw: _guard(handle, r, context))
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()


def _guard(function, raw, context):
    try:
        function(raw, context)
    except (ssl.SSLError, EOFError, ConnectionError):
        # The wrong-certificate probe aborts its handshake on purpose.
        pass


if __name__ == "__main__":
    main()
