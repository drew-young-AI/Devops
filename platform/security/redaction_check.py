#!/usr/bin/env python3
"""How much of the PII this platform will one day hold does v1 redaction catch?

WHY THIS EXISTS (2026-09-01)
----------------------------
`config.alloy` is honest in its own comment:

    v1 scope, stated honestly: three high-confidence patterns. This is a
    mechanism with a starter ruleset, not a complete de-identification
    solution.

And `docs/Backlog.md` §6 makes finishing it a hard prerequisite before any real
CYCH data reaches this platform. But "not a complete solution" is a sentence,
not a number, and nobody can plan against a sentence. This turns it into a
named list: which classes of identifier are caught, which are not, and which
ones matter for a hospital dataset.

It also answers a question nothing was asking: do the three rules still work?
`platform/observability/README.md` records "Verified end-to-end, by generating
real PII" -- one manual check, in August. A regex could have been broken since
and nothing would say so.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It does not design v2. Choosing replacement rules for a hospital extract needs
the actual schema, and inventing one would be exactly the "force a data mapping
without evidence" this platform forbids. Every value below is synthetic and
invented for the test.

ENGINE CAVEAT
-------------
Alloy runs these under Go's RE2; this runs them under Python's `re`. They agree
on the subset in use (character classes, \\b, {n,}, alternation). The one way
they could disagree catastrophically is a construct RE2 rejects -- a lookaround
or a backreference compiles in Python and is REFUSED by RE2, which would leave
Alloy running with the stage silently absent. That is checked explicitly.

Usage:
  redaction_check.py [--config PATH] [--out PATH] [--json]

Exit codes:
  0  rules parsed and evaluated
  2  fewer than the expected rules found, or the two blocks disagree
"""

import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_CONFIG = os.path.join(
    REPO_ROOT, "platform", "observability", "alloy", "config.alloy"
)

# One `loki.process "redact_*"` block, and the stage.replace pairs inside it.
BLOCK = re.compile(r'loki\.process\s+"(redact_[a-z]+)"\s*\{(.*?)\n\}', re.S)
STAGE = re.compile(
    r'stage\.replace\s*\{\s*expression\s*=\s*"((?:[^"\\]|\\.)*)"\s*'
    r'replace\s*=\s*"([^"]*)"',
    re.S,
)

# Constructs RE2 does not support. A rule using one compiles in Python and is
# rejected by Alloy, which is the worst possible outcome: the config still
# reads as though redaction is configured.
RE2_UNSUPPORTED = re.compile(r"\(\?[=!<]|\\[1-9]")

# The identifier classes a hospital log stream can realistically carry.
# `expected` says whether v1 claims this class; the test asserts every claimed
# class is actually caught, and reports the rest by name.
#
# EVERY VALUE IS SYNTHETIC. No real identifier appears in this file.
CLASSES = [
    # --- what v1 claims -----------------------------------------------------
    {"name": "台灣身分證字號", "expected": True, "sample": "patient id A123456789 admitted"},
    {"name": "email", "expected": True, "sample": "contact nurse.wang@example.invalid today"},
    {"name": "GitHub PAT", "expected": True,
     "sample": "token ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345 leaked"},
    {"name": "Vault service token", "expected": True,
     "sample": "auth hvs.CAESIJxxxxxxxxxxxxxxxxxxxxxxxx used"},
    # --- what it does not, and what each one costs in a hospital dataset ----
    {"name": "健保卡號 (NHI card)", "expected": False, "sample": "nhi card 000012345678 scanned",
     "why": "12 digits, no letter prefix -- indistinguishable from any other long number"},
    {"name": "病歷號 (medical record no.)", "expected": False, "sample": "chart no 0912345 pulled",
     "why": "site-specific format; needs the CYCH schema before a pattern can exist"},
    {"name": "手機號碼", "expected": False, "sample": "reachable on 0912-345-678",
     "why": "collides with dates, ports and row counts unless anchored to context"},
    {"name": "出生日期", "expected": False, "sample": "dob 1984-03-11 recorded",
     "why": "identical in form to every timestamp in these logs"},
    {"name": "姓名（自由文字）", "expected": False, "sample": "reviewed by 王小明 at triage",
     "why": "no lexical signal; needs a name list or NER, not a regex"},
    {"name": "地址", "expected": False, "sample": "resident of 嘉義市西區某某路 123 號",
     "why": "free text; the config comment already says so"},
]

# Ordinary log lines that must survive untouched. A redactor that redacts
# everything passes every positive control and destroys the logs.
BENIGN = [
    {"name": "一般請求日誌", "sample": '"GET /health/ready HTTP/1.1" 503 -'},
    {"name": "版本與 sha", "sample": "deployed blue-v15 sha 3e1b02c schema 15"},
    {"name": "指標數字", "sample": "monitoring 6503799 rows, population 632469 rows"},
    {"name": "容器名稱", "sample": "container station2-twin-blue-854764bdf9-bpp6l ready"},
    {"name": "時間戳", "sample": "checked_at 2026-09-01T06:42:24Z verdict HEALTHY"},
]


def parse(config_path):
    with open(config_path, "r") as handle:
        source = handle.read()
    blocks = {}
    for name, body in BLOCK.findall(source):
        rules = []
        for expression, replacement in STAGE.findall(body):
            # The config is HCL-ish: `\\b` in the file is a literal backslash-b
            # for the regex engine, so one level of unescaping is right here.
            rules.append({"expression": expression.replace("\\\\", "\\"),
                          "replace": replacement})
        blocks[name] = rules
    return blocks


def apply_rules(rules, text):
    out = text
    for rule in rules:
        try:
            out = re.sub(rule["expression"], rule["replace"], out)
        except re.error:
            # A rule Python cannot compile is a finding, not a crash -- it is
            # reported through re2_incompatible / compile_errors instead.
            continue
    return out


def build(config_path):
    blocks = parse(config_path)
    names = sorted(blocks)
    rule_sets = [blocks[n] for n in names]

    identical = bool(rule_sets) and all(r == rule_sets[0] for r in rule_sets)
    rules = rule_sets[0] if rule_sets else []

    incompatible = [r["expression"] for r in rules if RE2_UNSUPPORTED.search(r["expression"])]
    compile_errors = []
    for rule in rules:
        try:
            re.compile(rule["expression"])
        except re.error as exc:
            compile_errors.append({"expression": rule["expression"], "error": str(exc)})

    covered = []
    uncovered = []
    for cls in CLASSES:
        redacted = apply_rules(rules, cls["sample"]) != cls["sample"]
        row = {"name": cls["name"], "expected": cls["expected"], "redacted": redacted}
        if "why" in cls:
            row["why"] = cls["why"]
        (covered if cls["expected"] else uncovered).append(row)

    benign = [
        {"name": b["name"], "redacted": apply_rules(rules, b["sample"]) != b["sample"]}
        for b in BENIGN
    ]

    # An uncovered class that IS redacted is not good news -- it means a rule is
    # matching something it was never designed for, which is how a redactor
    # starts eating real log content.
    overreach = [c["name"] for c in uncovered if c["redacted"]]

    return {
        "schema": "redaction-coverage/1",
        "config": os.path.relpath(config_path, REPO_ROOT),
        "blocks": len(blocks),
        "block_names": names,
        "blocks_identical": identical,
        "rules_per_block": len(rules),
        "re2_incompatible": len(incompatible),
        "re2_incompatible_expressions": incompatible,
        "compile_errors": compile_errors,
        "classes_total": len(CLASSES),
        "covered": covered,
        "uncovered": uncovered,
        "uncovered_count": len(uncovered),
        "overreach": overreach,
        "benign": benign,
        "note": (
            "uncovered means NOT LOOKED FOR, not proven absent. v1 is a "
            "mechanism with a starter ruleset; this file states its edge in "
            "named classes so v2 has something to be scoped against."
        ),
    }


def main(argv):
    config = DEFAULT_CONFIG
    out = None
    as_json = False

    index = 0
    while index < len(argv):
        if argv[index] == "--config":
            config = argv[index + 1]; index += 2
        elif argv[index] == "--out":
            out = argv[index + 1]; index += 2
        elif argv[index] == "--json":
            as_json = True; index += 1
        else:
            sys.stderr.write("unknown argument: %s\n" % argv[index])
            return 2

    report = build(config)

    if out:
        with open(out, "w") as handle:
            json.dump(report, handle, indent=2, ensure_ascii=False)
            handle.write("\n")

    if report["rules_per_block"] == 0 or report["blocks"] == 0:
        sys.stderr.write(
            "REFUSED: parsed %d block(s) and %d rule(s) from %s.\n"
            "  Reporting 'no drift, all clean' from zero rules is the vacuous\n"
            "  pass this check exists to prevent.\n"
            % (report["blocks"], report["rules_per_block"], config)
        )
        return 2

    if as_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    print("write-time redaction (%s)" % report["config"])
    print("  %d rule(s), declared in %d block(s): %s"
          % (report["rules_per_block"], report["blocks"], ", ".join(report["block_names"])))
    print("  blocks identical: %s   RE2-incompatible rules: %d"
          % (report["blocks_identical"], report["re2_incompatible"]))
    print("  caught:")
    for row in report["covered"]:
        print("    %s %s" % ("OK  " if row["redacted"] else "MISS", row["name"]))
    print("  NOT looked for (%d of %d classes) -- scope for v2:"
          % (report["uncovered_count"], report["classes_total"]))
    for row in report["uncovered"]:
        print("    --   %-26s %s" % (row["name"], row.get("why", "")))
    if report["overreach"]:
        print("  OVERREACH -- redacting classes it was not designed for: %s"
              % ", ".join(report["overreach"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
