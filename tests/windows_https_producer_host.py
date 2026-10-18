"""Fresh-process real Windows HTTPS producer fixture (Python 3.12+).

The executable owns its loopback listener/explicit workers; this host only
prepares private bytes/Profile directories and records results. No external
HTTP request, certificate store change or TLS permission is made here.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

MODES = ("constructors", "complete", "cancel", "stop", "post_closed", "endpoint_close",
         "navigate", "recover", "wrong_certificate", "close_listener")
FILE_BYTES = 4 * 1024 * 1024


def plain(path):
    if path.is_symlink() or path.is_junction():
        raise RuntimeError(f"Refusing link/junction: {path}")


def hash_file(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def cleanup_created(directory, cache, expected):
    # This path belongs only to the fresh successful mode just created below.
    plain(directory)
    resolved = directory.resolve(strict=True)
    if resolved.parent != cache or resolved.name != expected or not resolved.is_dir():
        raise RuntimeError("Cleanup containment/name guard failed")
    # Refuse unexpected reparse points in the owned tree as well. Do not follow
    # them and never attempt any fallback shell deletion.
    for entry in resolved.rglob("*"):
        plain(entry)
        if not entry.resolve(strict=True).is_relative_to(resolved):
            raise RuntimeError("Cleanup descendant escaped mode directory")
    shutil.rmtree(resolved)


def main():
    if sys.version_info < (3, 12) or sys.platform != "win32":
        raise RuntimeError("Windows Python 3.12+ is required")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=pathlib.Path, required=True)
    parser.add_argument("--fixture", type=pathlib.Path, required=True)
    parser.add_argument("--cache", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--mode", choices=MODES, action="append")
    args = parser.parse_args()
    executable = args.exe.resolve(strict=True)
    fixture = args.fixture.resolve(strict=True)
    cache = args.cache.resolve(strict=True)
    plain(args.cache)
    plain(cache)
    if not executable.is_file() or not fixture.is_dir() or not cache.is_dir():
        raise RuntimeError("Invalid executable/fixture/cache")
    args.output.mkdir(parents=True, exist_ok=True)
    if (args.output / "results.json").exists() or any(args.output.glob("*.log")):
        raise RuntimeError("Evidence output already contains a run; preserve it")
    run_tag = hashlib.sha256(str(args.output.resolve(strict=True)).encode("utf-8")).hexdigest()[:12]
    certificate = fixture / "server-cert.pem"
    other = fixture / "other-cert.pem"
    identity = {"executable_sha256": hash_file(executable),
                "host_sha256": hash_file(pathlib.Path(__file__)),
                "certificate_sha256": hash_file(certificate),
                "other_certificate_sha256": hash_file(other)}
    results = []
    for mode in args.mode or MODES:
        name = "windows-https-producer-" + run_tag + "-" + mode
        directory = cache / name
        entry = {"mode": mode, "run_tag": run_tag, "exit_code": 127, "cleanup": "preserved",
                 "directory": str(directory), **identity}
        log = ""
        try:
            if directory.exists():
                raise RuntimeError("Fresh mode directory already exists")
            directory.mkdir()
            profile = directory / "profile"
            profile.mkdir()
            payload = directory / "private-bytes.bin"
            with payload.open("xb") as destination:
                for at in range(0, FILE_BYTES, 64 * 1024):
                    n = min(64 * 1024, FILE_BYTES - at)
                    destination.write(bytes((at + i) % 251 for i in range(n)))
            entry["payload_sha256"] = hash_file(payload)
            argv = [str(executable), mode, str(fixture), str(profile), str(payload)]
            result = subprocess.run(argv, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, encoding="utf-8", errors="replace",
                                    timeout=90, check=False)
            log = result.stdout
            entry["exit_code"] = result.returncode
            marker = "windows_https_producer_shutdown=confirmed mode=" + mode
            entry["shutdown_confirmed"] = marker in log
            if result.returncode == 0 and marker in log:
                cleanup_created(directory, cache, name)
                entry["cleanup"] = "removed_owned_success_directory"
            elif result.returncode == 0:
                entry["exit_code"] = 126
                entry["failure"] = "MissingShutdownMarker"
        except subprocess.TimeoutExpired as error:
            entry["failure"] = "FixtureTimeout"
            value = error.stdout or ""
            log = value.decode("utf-8", "replace") if isinstance(value, bytes) else value
        except Exception as error:
            entry["failure"] = type(error).__name__ + ": " + str(error)
            if entry["exit_code"] == 0:
                entry["exit_code"] = 125
        log_path = args.output / (mode + ".log")
        log_path.write_text(log, encoding="utf-8")
        entry["log_sha256"] = hash_file(log_path)
        results.append(entry)
        (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(entry, ensure_ascii=False), flush=True)
        if entry["exit_code"] != 0:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
