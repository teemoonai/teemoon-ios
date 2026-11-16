#!/usr/bin/env python3
"""check_no_debug_hooks.py — no NEW debug/test hook in the published source.

    python3 -I .github/scripts/check_no_debug_hooks.py [root] [--update]

Scans the publish set: the KEEP=( … ) paths of scripts/assemble_publish_candidate.sh
when root has that script (the private repo), else every file under root (the
public repo, or a candidate directory, IS the publish set). Every hit must be in
debug_hooks_allowlist.txt beside this script, matched by `path: trimmed line`
and counted, so a fourth identical `#if DEBUG` in a file that had three fails.
--update rewrites the allowlist from the tree; only run it for a hook pm approved.

App code (everything outside teemoonTests/ and teemoonUITests/): `#if/#elseif
… DEBUG`, `-uitesting`, `UITEST_`, `isUITesting`, a `["TEST_…"]`/`["UITEST_…"]`/
`["SIMULATOR_…"]` env read, `seededState`, `DesignTour`, `SCRATCH`. Comment-only
lines are skipped for all but SCRATCH. Test targets never ship in the app
binary and are the other end of every app-side hook (they launch with
--uitesting and set UITEST_ env), so there only SCRATCH counts.
"""
import collections
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOWLIST = os.path.join(HERE, "debug_hooks_allowlist.txt")
SELF = {os.path.join(".github", "scripts", n) for n in
        ("check_no_debug_hooks.py", "debug_hooks_allowlist.txt")}
TEST_DIRS = ("teemoonTests/", "teemoonUITests/")

APP_RULES = [
    ("#if DEBUG", re.compile(r"^\s*#\s*(if|elseif)\b.*\bDEBUG\b")),
    ("--uitesting", re.compile(r"-uitesting")),
    ("UITEST_", re.compile(r"UITEST_")),
    ("isUITesting", re.compile(r"isUITesting")),
    ("test env read", re.compile(r"\[\s*\"(TEST_|SIMULATOR_)[A-Za-z0-9_]*\"\s*\]")),
    ("seededState", re.compile(r"seededState")),
    ("DesignTour", re.compile(r"DesignTour")),
]
SCRATCH = ("SCRATCH", re.compile(r"SCRATCH"))
COMMENT = re.compile(r"^\s*(//|/\*|\*|#(?!\s*(if|elseif|else|endif)\b))")


def publish_paths(root):
    script = os.path.join(root, "scripts", "assemble_publish_candidate.sh")
    if not os.path.exists(script):
        return None
    m = re.search(r"^KEEP=\((.*?)^\)", open(script).read(), re.S | re.M)
    if not m:
        sys.exit(f"check_no_debug_hooks: cannot find KEEP=( … ) in {script}")
    return m.group(1).split()


def files(root, paths):
    if os.path.isdir(os.path.join(root, ".git")) or os.path.isfile(os.path.join(root, ".git")):
        out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", *(paths or ["."])],
                             check=True, capture_output=True).stdout
        return sorted(p for p in out.decode().split("\0") if p)
    found = []
    for top in paths or ["."]:
        full = os.path.join(root, top)
        if os.path.isfile(full):
            found.append(os.path.normpath(top))
        for d, dirs, names in os.walk(full):
            dirs[:] = [x for x in dirs if x != ".git"]
            found += [os.path.relpath(os.path.join(d, x), root) for x in names]
    return sorted(set(found))


def scan(root):
    hits = []  # (path, lineno, text, rule)
    for rel in files(root, publish_paths(root)):
        if rel in SELF:
            continue
        full = os.path.join(root, rel)
        if not os.path.isfile(full) or os.path.islink(full) or os.path.getsize(full) > 4_000_000:
            continue
        data = open(full, "rb").read()
        if b"\0" in data:
            continue
        is_test = rel.startswith(TEST_DIRS)
        for n, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            rules = [SCRATCH] if is_test or COMMENT.match(line) else APP_RULES + [SCRATCH]
            for name, rx in rules:
                if rx.search(line):
                    hits.append((rel, n, line.strip(), name))
                    break
    return hits


def key(path, text):
    return f"{path}: {text}"


def main(argv):
    update = "--update" in argv
    args = [a for a in argv if a != "--update"]
    root = os.path.abspath(args[0]) if args else os.getcwd()
    hits = scan(root)

    if update:
        with open(ALLOWLIST, "w") as f:
            f.write("# Debug/test hooks that exist in the published source, one line per occurrence.\n"
                    "# `path: trimmed line`; identical lines repeat. Written by\n"
                    "# check_no_debug_hooks.py --update — a new entry here is a pm decision.\n")
            for path, _, text, _ in hits:
                f.write(key(path, text) + "\n")
        print(f"check_no_debug_hooks: wrote {len(hits)} entries to {ALLOWLIST}")
        return 0

    allowed = collections.Counter(
        l.rstrip("\n") for l in open(ALLOWLIST, encoding="utf-8")
        if l.strip() and not l.startswith("# "))
    seen = collections.Counter()
    new = []
    for path, n, text, rule in hits:
        k = key(path, text)
        seen[k] += 1
        if seen[k] > allowed[k]:
            new.append(f"  {path}:{n}: {text}   [{rule}]")
    if new:
        print(f"check_no_debug_hooks: FAIL — {len(new)} new debug/test hook(s) in the published source:")
        print("\n".join(new))
        print("Remove it, or (pm decision) re-run with --update and commit the allowlist.")
        return 1
    gone = sum((allowed - seen).values())
    note = f"; {gone} allowlisted line(s) no longer present (--update to prune)" if gone else ""
    print(f"check_no_debug_hooks: ok — {len(hits)} known hook line(s), none new{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
