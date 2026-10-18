#!/usr/bin/env python3
"""Fetch/verify the optional Windows HTTPS TLS source release (Python 3.12+).

No system install, clone, generated configuration, overwrite or recursive delete.
An existing destination is verified against the pinned archive and preserved.
This private 3.6 provider is maintained upstream only through at least 2027-03;
its implementation is replaceable without changing the public byte protocol.
"""
import argparse
import hashlib
import os
import pathlib
import sys
import tarfile
import urllib.request

VERSION = "3.6.7"
SHA256 = "a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6"
ARCHIVE_BYTES = 5_473_689
URL = ("https://github.com/Mbed-TLS/mbedtls/releases/download/"
       f"mbedtls-{VERSION}/mbedtls-{VERSION}.tar.bz2")
SELECTED_LIMIT = 18 * 1024 * 1024
TOTAL_LIMIT = 24 * 1024 * 1024
SELECTED_TOP = {"include", "library", "3rdparty"}
SELECTED_ROOT = {"LICENSE", "SECURITY.md", "BRANCHES.md"}


def plain(path):
    if path.is_symlink() or path.is_junction():
        raise RuntimeError(f"Refusing link/junction: {path}")


def fetch(archive):
    # An interrupted download is preserved as evidence; do not overwrite it.
    temporary = archive.with_suffix(archive.suffix + ".download")
    digest = hashlib.sha256()
    count = 0
    with urllib.request.urlopen(URL, timeout=60) as response, temporary.open("xb") as output:
        while block := response.read(64 * 1024):
            count += len(block)
            if count > ARCHIVE_BYTES:
                raise RuntimeError("Pinned archive size exceeded")
            digest.update(block)
            output.write(block)
    if count != ARCHIVE_BYTES or digest.hexdigest() != SHA256:
        raise RuntimeError("Downloaded archive checksum/size mismatch")
    # Refuse overwrite even if another invocation won the same download race.
    # link is an atomic no-overwrite publication on both supported filesystems.
    # Only our just-created temporary name is removed after publication.
    os.link(temporary, archive)
    temporary.unlink()


def main():
    if sys.version_info < (3, 12):
        raise RuntimeError("Python 3.12+ is required")
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
    archive = deps / f"mbedtls-{VERSION}.tar.bz2"
    destination = deps / f"mbedtls-{VERSION}"
    plain(archive)
    plain(destination)
    if not archive.exists():
        if args.verify_only:
            raise RuntimeError("Pinned archive is absent")
        fetch(archive)
    if not archive.is_file() or archive.stat().st_size != ARCHIVE_BYTES:
        raise RuntimeError("Pinned archive size/type mismatch")
    with archive.open("rb") as input_file:
        if hashlib.file_digest(input_file, "sha256").hexdigest() != SHA256:
            raise RuntimeError("Pinned archive SHA256 mismatch")

    with tarfile.open(archive, "r:bz2") as source:
        selected = []
        names = set()
        payload = 0
        for index, member in enumerate(source):
            if index >= 4096:
                raise RuntimeError("Archive member bound exceeded")
            path = pathlib.PurePosixPath(member.name)
            if (not path.parts or path.parts[0] != f"mbedtls-{VERSION}"
                    or path.is_absolute() or ".." in path.parts
                    or "\\" in member.name or ":" in member.name):
                raise RuntimeError("Unsafe archive member path")
            relative = pathlib.PurePosixPath(*path.parts[1:])
            if not relative.parts:
                continue
            wanted = relative.parts[0] in SELECTED_TOP or str(relative) in SELECTED_ROOT
            if not wanted or member.isdir():
                continue
            if not member.isfile() or member.size < 0 or str(relative) in names:
                raise RuntimeError("Nonregular/duplicate selected member")
            names.add(str(relative))
            payload += member.size
            if payload > SELECTED_LIMIT or payload + ARCHIVE_BYTES > TOTAL_LIMIT:
                raise RuntimeError("Optional dependency extraction budget exceeded")
            selected.append((member, relative))
        existing = destination.exists()
        if args.verify_only and not existing:
            raise RuntimeError("Selected dependency directory is absent")
        if existing and not destination.is_dir():
            raise RuntimeError("Selected dependency path is not a directory")
        # The archive is fully validated before creating a new destination.
        if not existing:
            destination.mkdir()
        resolved_root = destination.resolve(strict=True)
        for member, relative in selected:
            target = destination.joinpath(*relative.parts)
            if not target.resolve().is_relative_to(resolved_root):
                raise RuntimeError("Selected member escaped destination")
            for parent in [target, *target.parents]:
                if parent == destination:
                    break
                plain(parent)
            with source.extractfile(member) as input_file:
                content = input_file.read(member.size + 1)
            if len(content) != member.size:
                raise RuntimeError("Selected member size mismatch")
            if existing:
                if not target.is_file() or target.read_bytes() != content:
                    raise RuntimeError(f"Existing dependency differs: {relative}")
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as output:
                    output.write(content)
        if not SELECTED_ROOT.issubset(names):
            raise RuntimeError("Original license/security notices are missing")
    print(f"Verified optional TLS {VERSION}: archive={ARCHIVE_BYTES} "
          f"selected={payload} total={payload + ARCHIVE_BYTES} files={len(selected)}")
    print(f"SHA256 {SHA256}")
    print(f"Source: {destination}")


if __name__ == "__main__":
    main()
