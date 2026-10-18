#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 - "$project" "$@" <<'PY'
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description="Preview generated Zig caches; preserve sources, dependencies, outputs and cache images.")
parser.add_argument("project", type=Path)
parser.add_argument("--apply", action="store_true")
parser.add_argument("--global", dest="global_cache", action="store_true", help="Also select the user's default Zig global cache")
parser.add_argument("--older-than-hours", type=float, default=24)
parser.add_argument("--cache-root", type=Path, help="Select one already recognized Linux cache root instead of all roots")
args = parser.parse_args()
if not 0 <= args.older_than_hours <= 87600:
    parser.error("--older-than-hours must be between 0 and 87600")
if sys.platform != "linux":
    parser.error("Run this script on Linux; Windows uses clean-cache.ps1")

generated = {"o", "h", "z", "tmp", "b"}
cutoff = time.time() - args.older_than_hours * 3600

def plain_directory(path):
    try:
        return not path.is_symlink() and path.is_dir()
    except (PermissionError, FileNotFoundError):
        return False

def cache_roots(base):
    if not plain_directory(base):
        return []
    result = []
    for child in base.iterdir():
        if not plain_directory(child) or child.name.startswith("checkpoint-"):
            continue
        # A local cache has h/o, a global cache has o/z.
        if plain_directory(child / "o") and any(plain_directory(child / name) for name in ("h", "z")):
            result.append(child)
    return result

project_cache = args.project.resolve() / ".zig-cache"
roots = [project_cache]
roots += cache_roots(project_cache)
if plain_directory(project_cache):
    roots += cache_roots(project_cache / "managed")
roots += cache_roots(Path.home() / ".cache" / "ziggurat")
roots += cache_roots(Path("/mnt/wsl/ziggurat-cache"))
if args.global_cache:
    roots.append(Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "zig")
roots = list(dict.fromkeys(root.absolute() for root in roots if plain_directory(root)))
# Linux /proc cannot inspect Windows compilers. Shared DrVFS caches therefore
# belong to the Windows script, which also checks whether WSL is running.
linux_roots = []
native_filesystems = {"ef53", "58465342", "9123683e", "1021994", "794c7630"}
for root in roots:
    # Match superblock magic: stat names the same shared filesystem 9p or v9fs
    # depending on its build. Unknown filesystems stay untouched as well.
    filesystem = subprocess.check_output(["stat", "-f", "-c", "%t", str(root)], text=True).strip().lower()
    if filesystem not in native_filesystems:
        print(f"KEEP {root} (shared or unsupported filesystem {filesystem}; use its host cleanup script)")
    else:
        linux_roots.append(root)
roots = linux_roots
if args.cache_root is not None:
    requested = args.cache_root.expanduser().absolute()
    if not plain_directory(requested):
        parser.error("The selected cache root must be an existing plain directory")
    selected_roots = [root for root in roots if root.resolve(strict=True) == requested.resolve(strict=True)]
    if len(selected_roots) != 1:
        parser.error("The selected cache root is not one recognized Linux cache directory")
    roots = selected_roots
    print(f"ROOT {roots[0]} (explicit recognized cache only)")

def assert_idle():
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            # comm remains readable when the executable has been unlinked.
            command = (proc / "comm").read_text().strip()
            if command == "zig":
                parser.error(f"A Zig compiler is running (PID {proc.name}); wait for builds/tests to finish")
            owned = proc.stat().st_uid == os.getuid()
            try:
                raw_exe = os.readlink(proc / "exe").removesuffix(" (deleted)")
            except PermissionError:
                if owned:
                    parser.error(f"Cannot inspect executable for PID {proc.name}; cleanup refused")
                continue
            executable = Path(os.path.realpath(raw_exe))
            if any(executable.is_relative_to(root.resolve()) for root in roots):
                parser.error(f"A cached executable is running (PID {proc.name}); wait for builds/tests to finish")
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            parser.error(f"Cannot inspect PID {proc.name}; cleanup refused")

def inspect(target):
    recent = target.stat().st_mtime > cutoff
    if recent:
        return True, False, 0
    linked = False
    size = 0
    def fail_scan(error):
        raise error
    for directory, dirs, files in os.walk(target, followlinks=False, onerror=fail_scan):
        for entry in dirs + files:
            path = Path(directory) / entry
            stat = path.lstat()
            if path.is_symlink():
                linked = True
                continue
            recent |= stat.st_mtime > cutoff
            if path.is_file():
                size += stat.st_size
        if linked or recent:
            break
    return recent, linked, size

if args.apply:
    assert_idle()

selected = 0
for root in roots:
    resolved_root = root.resolve(strict=True)
    for name in sorted(generated):
        target = root / name
        if not plain_directory(target):
            continue
        # Never remove a root, an aliased root or a linked descendant.
        if target.resolve(strict=True).parent != resolved_root:
            raise RuntimeError("Cache target escaped its registered parent: " + str(target))
        try:
            recent, linked, size = inspect(target)
        except (PermissionError, FileNotFoundError):
            print(f"KEEP {target} (unreadable or changed during inspection)")
            continue
        if linked or recent:
            print(f"KEEP {target} (recent or contains a symlink)")
            continue
        selected += size
        print(f"{'SELECT' if args.apply else 'PREVIEW'} {target} ({size / 1024**2:.1f} MiB)")
        if args.apply:
            assert_idle()
            if not plain_directory(target) or target.resolve(strict=True).parent != resolved_root:
                raise RuntimeError("Cache changed during cleanup")
            recent, linked, _ = inspect(target)
            if recent or linked:
                print(f"KEEP {target} (changed during cleanup)")
                continue
            assert_idle()
            shutil.rmtree(target)
print(f"Selected {selected / 1024**2:.1f} MiB. Mode: {'apply' if args.apply else 'preview'}.")
PY
