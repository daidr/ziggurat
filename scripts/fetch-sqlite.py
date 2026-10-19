#!/usr/bin/env python3
"""Fetch/verify the optional SQLite amalgamation source release (Python 3.9+).

No system install, clone, generated configuration, overwrite or recursive delete.
An existing destination is verified against the pinned archive and preserved.
Only the library translation unit and its two public headers are extracted;
the command-line shell source is not part of the build.
"""
import argparse
import hashlib
import os
import pathlib
import sys
import zipfile

VERSION = "3.54.1"
NUMBER = "3540100"
YEAR = "2026"
SHA256 = "0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9"
# The release page publishes SHA3-256; both digests are checked.
SHA3_256 = "92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30"
ARCHIVE_BYTES = 2_990_966
URL = f"https://sqlite.org/{YEAR}/sqlite-amalgamation-{NUMBER}.zip"
SELECTED = {"sqlite3.c", "sqlite3.h", "sqlite3ext.h"}
SELECTED_LIMIT = 16 * 1024 * 1024
MEMBER_LIMIT = 16


def plain(path):
    junction = getattr(path, "is_junction", None)
    if path.is_symlink() or (junction is not None and junction()):
        raise RuntimeError(f"Refusing link/junction: {path}")


def digests(data):
    return hashlib.sha256(data).hexdigest(), hashlib.sha3_256(data).hexdigest()


def fetch(archive):
    import urllib.request
    # An interrupted download is preserved as evidence; do not overwrite it.
    temporary = archive.with_suffix(archive.suffix + ".download")
    data = bytearray()
    with urllib.request.urlopen(URL, timeout=60) as response, temporary.open("xb") as output:
        while True:
            block = response.read(64 * 1024)
            if not block:
                break
            data += block
            if len(data) > ARCHIVE_BYTES:
                raise RuntimeError("Pinned archive size exceeded")
            output.write(block)
    if len(data) != ARCHIVE_BYTES or digests(bytes(data)) != (SHA256, SHA3_256):
        raise RuntimeError("Downloaded archive checksum/size mismatch")
    # link is an atomic no-overwrite publication; only our temporary is removed.
    os.link(temporary, archive)
    temporary.unlink()


def main():
    if sys.version_info < (3, 9):
        raise RuntimeError("Python 3.9+ is required")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true",
                        help="Verify existing archive and files, without download/extraction")
    args = parser.parse_args()
    workspace = pathlib.Path(__file__).resolve().parent.parent
    deps = workspace / ".deps"
    plain(deps)
    if not deps.exists():
        if args.verify_only:
            raise RuntimeError("No dependency directory to verify")
        deps.mkdir()
    if not deps.is_dir():
        raise RuntimeError("Dependency path is not a directory")
    archive = deps / f"sqlite-amalgamation-{NUMBER}.zip"
    destination = deps / f"sqlite-{VERSION}"
    plain(archive)
    plain(destination)
    if not archive.exists():
        if args.verify_only:
            raise RuntimeError("Pinned archive is absent")
        fetch(archive)
    if not archive.is_file() or archive.stat().st_size != ARCHIVE_BYTES:
        raise RuntimeError("Pinned archive size/type mismatch")
    if digests(archive.read_bytes()) != (SHA256, SHA3_256):
        raise RuntimeError("Pinned archive digest mismatch")

    prefix = f"sqlite-amalgamation-{NUMBER}"
    with zipfile.ZipFile(archive) as source:
        members = source.infolist()
        if len(members) > MEMBER_LIMIT:
            raise RuntimeError("Archive member bound exceeded")
        selected = []
        payload = 0
        for member in members:
            path = pathlib.PurePosixPath(member.filename)
            if (not path.parts or path.parts[0] != prefix or path.is_absolute()
                    or ".." in path.parts or "\\" in member.filename or ":" in member.filename):
                raise RuntimeError("Unsafe archive member path")
            if member.is_dir() or len(path.parts) != 2 or path.parts[1] not in SELECTED:
                continue
            payload += member.file_size
            if payload > SELECTED_LIMIT:
                raise RuntimeError("Optional dependency extraction budget exceeded")
            selected.append((member, path.parts[1]))
        if {name for _, name in selected} != SELECTED or len(selected) != len(SELECTED):
            raise RuntimeError("Expected amalgamation files are missing or duplicated")
        existing = destination.exists()
        if args.verify_only and not existing:
            raise RuntimeError("Selected dependency directory is absent")
        if existing and not destination.is_dir():
            raise RuntimeError("Selected dependency path is not a directory")
        # The archive is fully validated before creating a new destination.
        if not existing:
            destination.mkdir()
        for member, name in selected:
            target = destination / name
            plain(target)
            content = source.read(member)
            if len(content) != member.file_size:
                raise RuntimeError("Selected member size mismatch")
            if existing:
                if not target.is_file() or target.read_bytes() != content:
                    raise RuntimeError(f"Existing dependency differs: {name}")
            else:
                with target.open("xb") as output:
                    output.write(content)
    print(f"Verified optional SQLite {VERSION}: archive={ARCHIVE_BYTES} "
          f"selected={payload} files={len(selected)}")
    print(f"SHA256 {SHA256}")
    print(f"Source: {destination}")


if __name__ == "__main__":
    main()
