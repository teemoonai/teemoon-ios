#!/usr/bin/env python3
"""check_test_log.py — an xcodebuild test log is green only if its summary says
passed AND no test host crashed on the way there.

    python3 -I .github/scripts/check_test_log.py <xcodebuild.log>

xcodebuild relaunches a crashed test host ("Restarting after unexpected exit,
crash, or test timeout; summary will include totals from previous launches.")
and can still end "** TEST SUCCEEDED **" / "Test run with N tests passed". That
crash is a failure: this exits 1 and names the test(s) running when it happened.
It also exits 1 on a failed summary and on a log with no summary at all.

Lives under .github/ (not tools/) because .github is in the publish set and CI
runs on the public repo, where tools/ does not exist.
"""
import re
import sys

RESTART = "Restarting after unexpected exit"
# XCTest: Test Case '-[Mod.Class testX]' started.   Swift Testing: <sym> Test foo() started.
XC = re.compile(r"Test Case '([^']+)' (started|passed|failed|skipped)")
ST_START = re.compile(r"\bTest (.+?) started\.\s*$")
ST_END = re.compile(r"\bTest (.+?) (passed|failed|skipped)\b")
PASSED = [re.compile(p) for p in (
    r"\*\* TEST (EXECUTE )?SUCCEEDED \*\*",
    r"\bTest run with \d+ tests?\b.* passed\b",
    r"\bExecuted \d+ tests?, with 0 failures\b",
)]
FAILED = [re.compile(p) for p in (
    r"\*\* (TEST|BUILD|TEST EXECUTE) FAILED \*\*",
    r"\bTest run with \d+ tests?\b.* failed\b",
    r"\bExecuted \d+ tests?, with [1-9]\d* failures?\b",
)]


def main(path):
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        print(f"check_test_log: FAIL — cannot read {path}: {e}")
        return 1

    running = {}          # name -> line number, started and not yet finished
    last_started = None
    restarts = []         # (line number, line, [tests running], last started)
    passed = failed = False
    for n, line in enumerate(lines, 1):
        if RESTART in line:
            restarts.append((n, line.strip(), sorted(running, key=running.get), last_started))
            running.clear()
            continue
        m = XC.search(line)
        if m:
            name, verb = m.groups()
        else:
            name = verb = None
            if "Test Suite" not in line:
                if (m := ST_START.search(line)):
                    name, verb = m.group(1), "started"
                elif (m := ST_END.search(line)):
                    name, verb = m.groups()
        if name and name != "run":  # "◇ Test run started." is the whole run, not a test
            if verb == "started":
                running[name] = n
                last_started = name
            else:
                running.pop(name, None)
        passed |= any(p.search(line) for p in PASSED)
        failed |= any(p.search(line) for p in FAILED)

    problems = []
    for n, line, live, last in restarts:
        who = ", ".join(live) if live else (last or "(no test had started)")
        problems.append(f"line {n}: the test host crashed and was relaunched while running: {who}\n"
                        f"    {line}")
    if not passed and not failed:
        problems.append("no test summary in the log (no '** TEST SUCCEEDED/FAILED **', "
                        "'Test run with …', or 'Executed … tests') — the run did not finish")
    elif failed:
        problems.append("the summary reports a failure")

    if problems:
        print(f"check_test_log: FAIL — {path}")
        for p in problems:
            print("  " + p)
        if restarts and passed and not failed:
            print("  (xcodebuild's summary reads passed: it counts the relaunched host only)")
        return 1
    print(f"check_test_log: ok — {path} (summary passed, no host restarts)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check_test_log.py <xcodebuild.log>")
    sys.exit(main(sys.argv[1]))
