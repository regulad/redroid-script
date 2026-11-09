#!/usr/bin/env python3
"""Compares two image layers entry by entry.

    compare-layers.py <expected> <actual> [--ignore-mtime PATH]...

Each layer is a tar archive, compressed or not, as a registry or `docker save`
hands it out. For every path it compares the entry's type, mode, owner, size,
link target, content (SHA-256) and mtime, and prints each difference. It exits
0 when the only differences are mtimes of paths given with --ignore-mtime, and
1 otherwise.
"""

import argparse
import hashlib
import sys
import tarfile

FIELDS = ("type", "mode", "uid", "gid", "size", "link", "sha256", "mtime")


def read_layer(path):
    entries = {}
    with tarfile.open(path, "r:*") as tar:
        for member in tar:
            name = member.name.removeprefix("./").rstrip("/")
            digest = None
            if member.isfile():
                h = hashlib.sha256()
                with tar.extractfile(member) as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                digest = h.hexdigest()
            entries[name] = {
                "type": member.type.decode(),
                "mode": oct(member.mode & 0o7777),
                "uid": member.uid,
                "gid": member.gid,
                "size": member.size if member.isfile() else 0,
                "link": member.linkname,
                "sha256": digest,
                "mtime": int(member.mtime),
            }
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("expected")
    parser.add_argument("actual")
    parser.add_argument("--ignore-mtime", action="append", default=[], metavar="PATH")
    args = parser.parse_args()
    ignore_mtime = {p.rstrip("/") for p in args.ignore_mtime}

    expected = read_layer(args.expected)
    actual = read_layer(args.actual)

    failures = 0
    tolerated = 0
    for name in sorted(expected.keys() | actual.keys()):
        if name not in actual:
            print(f"missing   {name}")
            failures += 1
            continue
        if name not in expected:
            print(f"extra     {name}")
            failures += 1
            continue
        for field in FIELDS:
            a, b = expected[name][field], actual[name][field]
            if a == b:
                continue
            if field == "mtime" and name in ignore_mtime:
                print(f"tolerated {name}: mtime {a} -> {b}")
                tolerated += 1
            else:
                print(f"differs   {name}: {field} {a} -> {b}")
                failures += 1

    same = sum(1 for n in expected if n in actual and expected[n] == actual[n])
    print(
        f"{len(expected)} entries expected, {len(actual)} built; "
        f"{same} identical, {tolerated} tolerated differences, {failures} other differences"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
