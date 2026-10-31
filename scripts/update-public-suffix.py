#!/usr/bin/env python3
"""Regenerates src/webview/public_suffix.dat from the Public Suffix List.

Keeps every ICANN and private rule, one per line, with internationalized
labels in punycode (hosts reach the content rule matcher in that form), and
drops the list's comments except its license notice.

    python3 scripts/update-public-suffix.py [path-to-public_suffix_list.dat]

Without a path it downloads https://publicsuffix.org/list/public_suffix_list.dat.
"""
import datetime
import pathlib
import sys
import urllib.request

SOURCE = "https://publicsuffix.org/list/public_suffix_list.dat"
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "src" / "webview" / "public_suffix.dat"


def ascii_rule(rule: str) -> str:
    prefix = ""
    if rule.startswith("!"):
        prefix, rule = "!", rule[1:]
    labels = []
    for label in rule.split("."):
        if label == "*" or label.isascii():
            labels.append(label.lower())
        else:
            labels.append(label.encode("idna").decode("ascii"))
    return prefix + ".".join(labels)


def main() -> None:
    if len(sys.argv) > 1:
        text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    else:
        with urllib.request.urlopen(SOURCE) as response:
            text = response.read().decode("utf-8")
    lines = text.splitlines()
    notice = []
    for line in lines:
        if not line.startswith("//"):
            break
        notice.append(line)
    rules = []
    seen = set()
    for line in lines:
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        rule = ascii_rule(line.split()[0])
        if rule not in seen:
            seen.add(rule)
            rules.append(rule)
    header = notice + [f"// Generated from {SOURCE} on {datetime.date.today().isoformat()}", "// by scripts/update-public-suffix.py: comments removed, labels in punycode."]
    OUTPUT.write_text("\n".join(header + rules) + "\n", encoding="ascii")
    print(f"{len(rules)} rules written to {OUTPUT}")


if __name__ == "__main__":
    main()
