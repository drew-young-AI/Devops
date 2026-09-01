#!/usr/bin/env python3
"""OKF v0.1 conformance check for this repository's markdown.

Open Knowledge Format is Google Cloud's vendor-neutral markdown spec (v0.1,
2026-06-12) for knowledge that AI agents consume: a directory of markdown
files with YAML frontmatter, cross-linked into a graph.
Spec: https://okf.md/spec/

WHY A CHECKER FIRST, BEFORE TOUCHING A SINGLE DOCUMENT.

Hand-adding frontmatter to two dozen files and never verifying again means
the standard is broken within a month and nobody notices -- the documents
still render, still read fine, and quietly stop being machine-consumable.
That is the same failure shape as every other silent defect this platform
has had to guard against: it looks like compliance.

Adopting a standard is the checker. The frontmatter is just the artifact.

CONFORMANCE, quoting the spec's three criteria:

  1. "Every non-reserved `.md` file in the tree contains a parseable YAML
     frontmatter block."
  2. "Every frontmatter block contains a non-empty `type` field."
  3. Reserved files follow prescribed structures when present.

Reserved filenames (`index.md`, `log.md`) must have NO frontmatter. That
detail matters here: it is the spec agreeing that a chronological log is not
a concept document and should not be dressed as one.

The spec is deliberately permissive about everything else -- consumers "must
not reject bundles for missing optional fields, unknown types, broken links,
or absent index files". This checker therefore separates:

  ERROR   violates a normative requirement (fails the build)
  WARN    house convention this repo chose (reported, does not fail)

Conflating the two would mean enforcing our taste as if it were the spec.

Usage:
  okf_check.py [--json] [--strict]     --strict also fails on warnings
"""

import argparse
import json
import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RESERVED = {"index.md", "log.md"}

# Directories that are not part of the knowledge bundle.
# `venv` as well as `.venv`, and site-packages explicitly: a dependency that
# vendors a LICENSE.md is not part of this repo's knowledge bundle, and treating
# it as one turns the conformance gate into a report about other people's
# packaging. Found the day platform/analytics/venv/ appeared -- two vendored
# idna licence files failed the gate while every document we actually wrote
# passed.
SKIP_DIRS = {".git", "node_modules", "archives", "__pycache__",
             ".venv", "venv", "site-packages"}

# House conventions, NOT spec requirements. The spec requires only `type`.
# These are recommended fields the spec lists as prioritized, and this repo
# treats the first two as expected because a bundle whose concepts have no
# description is one an agent has to open every file to search.
EXPECTED = ("title", "description")

# Type values are explicitly not registered centrally by the spec ("Teams
# establish their own conventions"). This is ours, kept small on purpose: a
# taxonomy nobody can hold in their head gets used inconsistently.
KNOWN_TYPES = {
    "platform-adapter",   # a platform/ capability: what it does and why
    "runbook",            # a procedure a human executes
    "how-to",             # task-oriented instructions
    "reference",          # lookup material
    "explanation",        # design rationale, decisions
    "plan",               # intended work, not yet true
    "checklist",          # things to verify
    "review",             # a point-in-time assessment
    "overview",           # entry point for a directory or the repo
}


def parse_frontmatter(text):
    """Returns (frontmatter_dict_or_None, error_or_None).

    A hand-rolled parser rather than PyYAML on purpose for the delimiter
    scan, then PyYAML for the body -- the failure mode worth catching is a
    missing or malformed delimiter, which PyYAML alone reports as a confusing
    type error on the whole document.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, "no frontmatter block (file does not start with ---)"
    for i in range(1, len(lines)):
        if lines[i].strip() in ("---", "..."):
            block = "\n".join(lines[1:i])
            try:
                import yaml
                data = yaml.safe_load(block)
            except Exception as exc:  # noqa: BLE001
                return None, f"frontmatter is not parseable YAML: {exc}"
            if data is None:
                return {}, None
            if not isinstance(data, dict):
                return None, "frontmatter is not a YAML mapping"
            return data, None
    return None, "frontmatter block is never closed"


def check_file(path, rel):
    """Returns (errors, warnings) for one markdown file."""
    errors, warnings = [], []
    name = os.path.basename(path)
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        return [f"unreadable: {exc}"], []

    if name in RESERVED:
        # Criterion 3: reserved files must NOT carry frontmatter.
        if text.startswith("---"):
            errors.append(f"reserved file '{name}' must not have frontmatter")
        return errors, warnings

    data, err = parse_frontmatter(text)
    if err:
        errors.append(err)          # criterion 1
        return errors, warnings

    type_value = data.get("type")
    if not type_value or not str(type_value).strip():
        errors.append("missing or empty required field: type")   # criterion 2
    elif type_value not in KNOWN_TYPES:
        # A warning, never an error: the spec says consumers must handle
        # unknown types gracefully, so failing on one would be stricter than
        # the standard and would punish a legitimate new concept kind.
        warnings.append(f"type '{type_value}' is outside this repo's taxonomy")

    for field in EXPECTED:
        if not data.get(field):
            warnings.append(f"missing recommended field: {field}")

    desc = data.get("description")
    if desc and len(str(desc)) > 200:
        warnings.append("description is longer than a sentence")

    return errors, warnings


def scan():
    results = []
    for root, dirs, files in os.walk(REPO_ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, REPO_ROOT)
            errors, warnings = check_file(path, rel)
            results.append({"file": rel, "reserved": name in RESERVED,
                            "errors": errors, "warnings": warnings})
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true",
                        help="also fail on house-convention warnings")
    args = parser.parse_args()

    results = scan()
    total = len(results)
    failing = [r for r in results if r["errors"]]
    warning = [r for r in results if r["warnings"] and not r["errors"]]
    conformant = total - len(failing)

    if args.json:
        print(json.dumps({
            "spec": "OKF v0.1",
            "files": total,
            "conformant": conformant,
            "conformance_pct": round(conformant * 100 / total, 1) if total else 0,
            "results": results,
        }, indent=2, ensure_ascii=False))
    else:
        print(f"OKF v0.1 conformance: {conformant}/{total} "
              f"({conformant * 100 / total:.0f}%)" if total else "no markdown found")
        for r in failing:
            print(f"  ERROR {r['file']}")
            for e in r["errors"]:
                print(f"        {e}")
        for r in warning:
            print(f"  warn  {r['file']}")
            for w in r["warnings"]:
                print(f"        {w}")

    if failing:
        return 1
    if args.strict and warning:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
