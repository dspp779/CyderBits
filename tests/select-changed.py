#!/usr/bin/env python3
"""Pick the tests affected by changed files (used by `tests/run.sh --changed`).

    python3 tests/select-changed.py [--base REF] [--files PATH ...]

Prints one test file name per line, or `ALL` when the whole suite must run.
Reasons go to stderr.

A test is affected when its own text names a changed file (by repo path or
basename), names a file under scripts/ that names a changed file (followed
transitively, e.g. a launcher that sources cyder-common.sh), or calls an
affected test. A changed Swift file does not pull in every app-build test:
`tests/run.sh --changed` typechecks the whole app instead (`--swift-changed`
says whether to), so a Swift file no test names selects nothing extra.
Documentation (*.md, docs/, .agents/) selects nothing. Runner files, or any
other file that no test names, select ALL.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER_FILES = {"tests/run.sh", "tests/assert.sh", "tests/select-changed.py"}
PACKAGING = {"create-cyder-app.sh", "create-cyderbits-app.sh", "release-cyder.sh",
             "build-cyder-lifecycle-test.sh"}
TEST_PATTERN = re.compile(r"^test-.*\.(sh|py|rb)$")


def git(*args):
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return [line for line in result.stdout.splitlines() if line]


def changed_files(base):
    files = set(git("diff", "--name-only", f"{base}...HEAD"))
    files |= set(git("diff", "--name-only", "HEAD"))
    files |= set(git("ls-files", "--others", "--exclude-standard"))
    return sorted(files)


def is_doc(path):
    return path.endswith(".md") or path.startswith(("docs/", ".agents/"))


def mentions(text, path):
    return path in text or Path(path).name in text


def select(files):
    tests = {p.name: p.read_text(errors="replace") for p in sorted((ROOT / "tests").iterdir())
             if TEST_PATTERN.match(p.name)}
    scripts = {}
    for p in sorted((ROOT / "scripts").rglob("*")):
        if p.is_file():
            try:
                scripts[str(p.relative_to(ROOT))] = p.read_text(errors="replace")
            except OSError:
                pass

    if not files:
        return [], "no changes"
    code = [f for f in files if not is_doc(f)]
    if not code:
        return [], "only documentation changed"
    runner = [f for f in code if f in RUNNER_FILES or f.startswith("tests/lib/")]
    if runner:
        return None, f"runner changed: {', '.join(runner)}"

    selected = set()
    unmatched = []
    for f in code:
        users = users_of(f, scripts)
        hits = {name for name, text in tests.items()
                if name == Path(f).name or any(mentions(text, u) for u in users)}
        if not hits and f.startswith("scripts/") and f.endswith(".swift"):
            continue  # covered by the whole-app typecheck
        if not hits:
            unmatched.append(f)
        selected |= hits
    if unmatched:
        return None, f"no test names: {', '.join(unmatched)}"

    # Tests that run a selected test are affected too.
    while True:
        more = {name for name, text in tests.items()
                if name not in selected and any(s in text for s in selected)}
        if not more:
            break
        selected |= more
    return sorted(selected), f"{len(selected)} tests for {len(code)} changed files"


def users_of(changed, scripts):
    """The changed file plus every scripts/ file that (transitively) names it.
    Packaging scripts name every file, so they do not pass a change on."""
    result = {changed}
    while True:
        more = {path for path, text in scripts.items() if path not in result
                and Path(path).name not in PACKAGING and any(mentions(text, r) for r in result)}
        if not more:
            return result
        result |= more


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="main")
    parser.add_argument("--files", nargs="*")
    parser.add_argument("--swift-changed", action="store_true",
                        help="print yes when a Swift file under scripts/ changed")
    args = parser.parse_args()
    files = args.files if args.files is not None else changed_files(args.base)
    if args.swift_changed:
        print("yes" if any(f.startswith("scripts/") and f.endswith(".swift") for f in files) else "no")
        return
    tests, reason = select(files)
    print(reason, file=sys.stderr)
    if tests is None:
        print("ALL")
    else:
        print("\n".join(tests))


if __name__ == "__main__":
    main()
