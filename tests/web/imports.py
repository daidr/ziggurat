"""Checks that each browser app imports only what web/ziggurat.js provides.

    python3 tests/web/imports.py zig-out/web

Every app.wasm under the directory may import WASI, the functions of the
"ziggurat" module that web/ziggurat.js provides (the page's own and the
WebGL2 calls of the OpenGL renderer, src/ui/gl_web.h) and the zsd_*
functions of "env"; any other import, such as a native renderer function a
new feature added only for the desktops, or a gl* call the page does not
run, makes the page fail to start with a LinkError, so it fails here first.
"""
import pathlib
import re
import sys


def leb(data, at):
    value = shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, at


def imports(data):
    at = 8
    while at < len(data):
        section = data[at]
        size, at = leb(data, at + 1)
        if section == 2:
            cursor = at
            count, cursor = leb(data, cursor)
            for _ in range(count):
                length, cursor = leb(data, cursor)
                module = data[cursor : cursor + length].decode()
                cursor += length
                length, cursor = leb(data, cursor)
                name = data[cursor : cursor + length].decode()
                cursor += length
                kind = data[cursor]
                cursor += 1
                if kind == 0:
                    _, cursor = leb(data, cursor)
                elif kind == 2:
                    flags = data[cursor]
                    _, cursor = leb(data, cursor + 1)
                    if flags & 1:
                        _, cursor = leb(data, cursor)
                else:
                    raise ValueError(f"unexpected import kind {kind} for {module}.{name}")
                yield module, name
        at += size


def main():
    root = pathlib.Path(sys.argv[1])
    apps = sorted(root.glob("*/app.wasm"))
    if not apps:
        sys.exit(f"imports: no app.wasm under {root}")
    page = pathlib.Path(__file__).resolve().parents[2] / "web" / "ziggurat.js"
    provided = set(re.findall(r"^\s*(\w+)\s*:", page.read_text(), re.M))
    bad = []
    for app in apps:
        for module, name in imports(app.read_bytes()):
            if module == "wasi_snapshot_preview1" or (module == "ziggurat" and name in provided) or (module == "env" and name.startswith("zsd_")):
                continue
            bad.append(f"{app.parent.name}: {module}.{name}")
    if bad:
        sys.exit("imports: the page does not provide\n  " + "\n  ".join(bad))
    print(f"imports: {len(apps)} apps import only what the page provides")


main()
