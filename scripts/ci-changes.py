#!/usr/bin/env python3
"""Decide which CI jobs a change needs.

Reads changed paths (one per line) on stdin and prints `name=true|false`
lines for $GITHUB_OUTPUT:

  windows, linux, macos  run that platform's native job
  release_tests          run the ReleaseSafe unit tests on Linux

A path whose name says it belongs to one platform (src/platform/macos.m,
scripts/fetch-webview2.ps1, tests/linux_regions_smoke.c, ...) selects only
that platform. Documentation selects nothing. Everything else - shared Zig
sources, build.zig, the workflow itself, unknown files - selects every
platform, so an unclear path never skips coverage.

A name is not enough for source files: shared code can import a file named
for one platform without an OS check (https_resources/transport.zig takes
types from windows_transport.zig on every OS), and then every platform
compiles it. So a platform-named source also selects every platform its
importers build for, followed up the import graph, unless the importing line
itself tests the OS (`os.tag == .windows`, `.linux, .macos =>`,
`if (windows)`). Run it from the repository root of the checked-out change.

  --all              select everything (pushes, manual runs, the full-ci
                     label)
  --release-tests    also run the ReleaseSafe unit tests
  --github-files     stdin holds pages of the pull request files API, one
                     JSON array per line; a renamed file counts under both
                     names, and a list at the API's 3000-file cap selects
                     everything
  --explain          print each path's platforms to stderr
"""

import json
import os
import re
import sys

PLATFORMS = ("windows", "linux", "macos")
ALL = frozenset(PLATFORMS)

# Checked in order; the first rule that matches a path decides it.
RULES = [
    # Text only: the native jobs never read these.
    (re.compile(r"^docs/|^[^/]+\.md$|^license$|^\.gitignore$|^a\.out$"), ()),
    # Build graph, toolchain pins and CI drive every job; macos_panic.zig is
    # the panic handler every platform's smokes share.
    (re.compile(r"^build\.zig(\.zon)?$|^\.github/|^build_support/native|^scripts/(ci-zig-cache|fetch-zig\.sh|ci-changes)|macos_panic"), PLATFORMS),
    (re.compile(r"macos|appkit|avfoundation|cocoa|darwin|metal|\.mm?$"), ("macos",)),
    (re.compile(r"windows|win32|webview2|d3d11|dxgi|media_foundation|uiautomation|\.ps1$|\.rc$|\.def$"), ("windows",)),
    # Only the Linux job builds these: GTK, X11, AT-SPI, GStreamer, Cairo,
    # and the WebAssembly apps with their browser smoke.
    (re.compile(r"gtk|x11|wayland|atspi|gstreamer|cairo|pango|^web/|^tests/web/|wasm"), ("linux",)),
    # macOS reuses many POSIX sources named after Linux (ui/linux.zig,
    # fonts/linux.zig, pty_linux.zig, clipboard_linux.zig) and the WebKit
    # bindings, and shell scripts run on both POSIX runners.
    (re.compile(r"linux|webkit|\.sh$"), ("linux", "macos")),
]

SOURCE_DIRS = ("src", "tests", "tools", "examples", "build_support")
SOURCE_EXTENSIONS = (".zig", ".c", ".h", ".m", ".mm")
REFERENCE = re.compile(r'(?:@import|@embedFile|#\s*include|#\s*import)\b[^"\n]*"([^"\n]+)"')
STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"')
GUARD = re.compile(
    r"\.(?:windows|linux|macos)\b"
    r"|\bif\s*\(\s*(?:comptime\s+)?[^)]*\b(?:is_)?(?:windows|linux|macos)\b"
)


def platforms_for(path):
    lowered = path.lower()
    for pattern, selected in RULES:
        if pattern.search(lowered):
            return frozenset(selected)
    return ALL


def is_source(path):
    return path.startswith(tuple(d + "/" for d in SOURCE_DIRS)) and path.endswith(SOURCE_EXTENSIONS)


class ImportGraph:
    """Who references each source file, and whether that line tests the OS."""

    def __init__(self, root="."):
        self.files = set()
        for top in SOURCE_DIRS:
            for directory, _, names in os.walk(os.path.join(root, top)):
                for name in names:
                    path = os.path.relpath(os.path.join(directory, name), root).replace(os.sep, "/")
                    if is_source(path):
                        self.files.add(path)
        by_name = {}
        for path in self.files:
            by_name.setdefault(path.rsplit("/", 1)[-1], []).append(path)
        self.importers = {}
        for importer in self.files:
            try:
                with open(os.path.join(root, importer), encoding="utf-8", errors="replace") as source:
                    lines = source.readlines()
            except OSError:
                continue
            base = importer.rsplit("/", 1)[0]
            for line in lines:
                for literal in REFERENCE.findall(line):
                    relative = os.path.normpath(os.path.join(base, literal)).replace(os.sep, "/")
                    # C include paths come from -I flags: match the name anywhere.
                    targets = [relative] if relative in self.files else by_name.get(literal.rsplit("/", 1)[-1], [])
                    guarded = bool(GUARD.search(STRING.sub('""', line)))
                    for target in targets:
                        self.importers.setdefault(target, []).append((importer, guarded))
        self.memo = {}

    def platforms(self, path):
        """Every platform that compiles `path`, over-approximated."""
        if path in self.memo:
            return self.memo[path]
        own = platforms_for(path)
        if own == ALL or path not in self.files:
            return own
        # A cycle back to this file adds nothing beyond its own name.
        self.memo[path] = own
        result = set(own)
        for importer, guarded in self.importers.get(path, ()):
            if guarded or importer == path:
                continue
            result |= self.platforms(importer)
            if result == ALL:
                break
        self.memo[path] = frozenset(result)
        return self.memo[path]


def read_paths(github_files):
    if not github_files:
        return [line.strip() for line in sys.stdin if line.strip()]
    paths = []
    count = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        for entry in json.loads(line):
            count += 1
            paths.append(entry["filename"])
            if entry.get("previous_filename"):
                paths.append(entry["previous_filename"])
    return None if count >= 3000 else paths


def main(argv):
    select_all = "--all" in argv
    selected = set()
    if not select_all:
        paths = read_paths("--github-files" in argv)
        select_all = paths is None
    if select_all:
        selected = set(PLATFORMS)
    else:
        graph = ImportGraph()
        for path in paths:
            platforms = graph.platforms(path) if is_source(path) else platforms_for(path)
            if "--explain" in argv:
                print(path + ": " + (" ".join(sorted(platforms)) or "-"), file=sys.stderr)
            selected |= platforms
    outputs = {name: name in selected for name in PLATFORMS}
    # Optimizer-only miscompiles live in shared code; a change that only
    # touches documentation or another OS's files cannot add one on Linux.
    outputs["release_tests"] = "--release-tests" in argv and outputs["linux"]
    for name, value in outputs.items():
        print(name + "=" + ("true" if value else "false"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
