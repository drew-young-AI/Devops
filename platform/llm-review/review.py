#!/usr/bin/env python3
"""Station 5 review engine -- see review.sh for the contract and rationale.

Design constraints that are not obvious from the code:

* The prompt is assembled in a FIXED order from FIXED sources and hashed
  (`inputs_digest`). That hash is what makes "same input -> same output"
  checkable after the fact: two review files with the same inputs_digest
  and different verdicts is a determinism failure you can actually detect,
  rather than something you'd have to take on faith.

* Nothing here reads a secret. Inputs are limited to git diff of the pilot
  directory and this repo's own evidence/*.json files (which by contract
  never contain secret values -- see platform/vault/README.md). The
  endpoint is 127.0.0.1 only, so no evidence leaves the machine.

* Every failure mode still writes an evidence file. A review that did not
  happen must leave a trace; silence is indistinguishable from "reviewed
  and fine", and that ambiguity is exactly what would rot this into
  security theatre.
"""

import argparse
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# Diff is truncated so a large refactor can't blow past the model's context
# and silently get reviewed on a fragment. Truncation is recorded in the
# evidence file rather than hidden.
MAX_DIFF_CHARS = 20000

SYSTEM_PROMPT = (
    "You are a DevOps release reviewer. You are given deterministic build "
    "evidence for a single commit of a single service. Review it and report "
    "concerns.\n"
    "\n"
    "You are producing LLM-generated evidence for a human reviewer. You do "
    "NOT grant approval and you do NOT decide whether anything ships.\n"
    "\n"
    "Base every finding strictly on the evidence supplied below. Do not "
    "speculate about code you were not shown. If the evidence is "
    "insufficient to judge something, say so as a finding rather than "
    "guessing.\n"
    "\n"
    "Reply with ONLY compact JSON, no markdown fence, matching exactly:\n"
    '{"verdict":"PASS"|"CONCERN"|"FAIL",'
    '"findings":[{"severity":"high"|"medium"|"low","area":"<short>",'
    '"detail":"<one sentence>"}],'
    '"summary":"<two sentences max>"}\n'
    "\n"
    'Use "FAIL" only for evidence of a concrete defect or a failed gate. '
    'Use "CONCERN" for risks worth a human look. Use "PASS" when the '
    "evidence supports release and findings is empty or low severity only."
)


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git(repo_root, *args):
    result = subprocess.run(
        ["git", "-C", repo_root, *args],
        capture_output=True,
        text=True,
    )
    return result.stdout if result.returncode == 0 else ""


def collect_diff(repo_root, pilot_dir, sha):
    """Diff of the pilot dir introduced by `sha`, or empty if it has no parent."""
    has_parent = git(repo_root, "rev-parse", "--verify", "--quiet", f"{sha}^").strip()
    if not has_parent:
        return "", False
    diff = git(repo_root, "diff", f"{sha}^", sha, "--", pilot_dir)
    if len(diff) > MAX_DIFF_CHARS:
        return diff[:MAX_DIFF_CHARS], True
    return diff, False


def load_evidence(evidence_dir, filename):
    path = os.path.join(evidence_dir, filename)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def find_evidence(evidence_dir, pattern):
    """First file matching `pattern`, chosen deterministically by sorted name."""
    if not os.path.isdir(evidence_dir):
        return None
    matches = sorted(f for f in os.listdir(evidence_dir) if re.fullmatch(pattern, f))
    if not matches:
        return None
    return load_evidence(evidence_dir, matches[0])


def build_prompt(pilot_name, sha, sources):
    """Fixed-order assembly. Order and formatting here ARE the contract --
    changing them changes every future inputs_digest."""
    blocks = [f"SERVICE: {pilot_name}", f"COMMIT: {sha}", ""]

    for label, payload in sources:
        blocks.append(f"--- {label} ---")
        if payload is None:
            blocks.append("(not present)")
        elif isinstance(payload, str):
            blocks.append(payload if payload.strip() else "(empty)")
        else:
            blocks.append(json.dumps(payload, sort_keys=True, indent=2, ensure_ascii=False))
        blocks.append("")

    return "\n".join(blocks)


def call_mlx(endpoint, model, timeout, thinking, prompt):
    """Returns (content, error_kind, error_detail). content is None on failure."""
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0,
        "top_p": 1,
        "max_tokens": 4096 if thinking else 1024,
        "chat_template_kwargs": {"enable_thinking": bool(thinking)},
    }
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/v1/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        return None, "HTTP_ERROR", f"{exc.code} {exc.reason}"
    except urllib.error.URLError as exc:
        # A timeout during connect surfaces here wrapped in URLError, while a
        # timeout while waiting for the model to generate surfaces as a bare
        # socket.timeout below. Both are the same operational condition and
        # must report the same kind.
        if isinstance(exc.reason, socket.timeout):
            return None, "TIMEOUT", f"no response within {timeout}s"
        return None, "UNAVAILABLE", str(exc.reason)
    except socket.timeout:
        # NOT `except TimeoutError` -- on Python 3.9 (the system python3 this
        # repo's scripts run on) socket.timeout is a plain OSError subclass and
        # is NOT an alias of TimeoutError; that only became true in 3.10.
        # Catching TimeoutError here silently misfiled every read timeout as
        # TRANSPORT_ERROR. Found by actually running the timeout test, not by
        # reading the code.
        return None, "TIMEOUT", f"no response within {timeout}s"
    except (OSError, json.JSONDecodeError) as exc:
        return None, "TRANSPORT_ERROR", str(exc)

    try:
        choice = payload["choices"][0]
        content = choice["message"].get("content")
    except (KeyError, IndexError, TypeError) as exc:
        return None, "MALFORMED_RESPONSE", f"unexpected response shape: {exc}"

    if not content:
        # Reasoning models spend the whole budget on `reasoning` and emit no
        # `content` when max_tokens is hit. Reported as its own kind because
        # the fix is different (raise max_tokens / disable thinking) from a
        # model that answered with unparseable text.
        reason = choice.get("finish_reason", "unknown")
        return None, "NO_CONTENT", f"empty content, finish_reason={reason}"

    return content, None, None


def parse_verdict(content):
    """Returns (parsed_dict, error) -- tolerant of a markdown fence, nothing more."""
    text = content.strip()
    fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", text, re.DOTALL)
    if fence:
        text = fence.group(1).strip()
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        return None, f"not valid JSON: {exc}"
    if not isinstance(parsed, dict):
        return None, "JSON root is not an object"
    verdict = parsed.get("verdict")
    if verdict not in ("PASS", "CONCERN", "FAIL"):
        return None, f"verdict not one of PASS/CONCERN/FAIL: {verdict!r}"
    return parsed, None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--pilot-dir", required=True)
    parser.add_argument("--pilot-name", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--evidence-dir", required=True)
    args = parser.parse_args()

    endpoint = os.environ.get("MLX_ENDPOINT", "http://127.0.0.1:9000")
    model = os.environ.get("MLX_MODEL", "mlx-community/Qwen3.6-35B-A3B-4bit")
    timeout = int(os.environ.get("MLX_TIMEOUT", "180"))
    thinking = os.environ.get("LLM_REVIEW_THINKING", "0") == "1"

    short_sha = args.sha[:7]
    diff, diff_truncated = collect_diff(args.repo_root, args.pilot_dir, args.sha)

    sources = [
        ("BUILD METADATA", load_evidence(args.evidence_dir, f"build_{short_sha}.json")),
        (
            "CONTAINER VULNERABILITY SCAN (Trivy gate)",
            find_evidence(args.evidence_dir, rf"trivy_summary_.*_{short_sha}\.json"),
        ),
        (
            "SBOM SUMMARY",
            find_evidence(args.evidence_dir, rf"sbom_summary_.*_{short_sha}\.json"),
        ),
        (
            "DEVELOP DEPLOYMENT",
            load_evidence(args.evidence_dir, f"deploy_develop_{short_sha}.json"),
        ),
        ("GIT DIFF (service directory only)", diff),
    ]

    prompt = build_prompt(args.pilot_name, short_sha, sources)
    inputs_digest = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
    system_digest = hashlib.sha256(SYSTEM_PROMPT.encode("utf-8")).hexdigest()

    content, error_kind, error_detail = call_mlx(endpoint, model, timeout, thinking, prompt)

    parsed, parse_error = (None, None)
    if content is not None:
        parsed, parse_error = parse_verdict(content)
        if parsed is None:
            error_kind, error_detail = "UNPARSEABLE_VERDICT", parse_error

    degraded = parsed is None

    record = {
        "evidence_type": "LLM-generated",
        "human_acceptance": None,
        "note": (
            "LLM-generated evidence only. Per NEW_SERVICE_GUIDE.md section 8 "
            "this does not constitute production release approval; a human "
            "decision is still required regardless of the verdict below."
        ),
        "service": args.pilot_name,
        "commit_sha": short_sha,
        "generated_at": utc_now(),
        "status": "OK" if not degraded else f"DEGRADED_{error_kind}",
        "verdict": parsed.get("verdict") if parsed else None,
        "summary": parsed.get("summary") if parsed else None,
        "findings": parsed.get("findings", []) if parsed else [],
        "error": None if not degraded else {"kind": error_kind, "detail": error_detail},
        "raw_response": content,
        "reproducibility": {
            "endpoint": endpoint,
            "model": model,
            "temperature": 0,
            "top_p": 1,
            "thinking_enabled": thinking,
            "inputs_digest_sha256": inputs_digest,
            "system_prompt_digest_sha256": system_digest,
            "diff_truncated": diff_truncated,
            "sources_present": {
                label: payload is not None and payload != ""
                for label, payload in sources
            },
        },
    }

    # Second-resolution timestamps collide: three runs inside one second (a
    # determinism check, or the degraded-mode tests) all resolved to the same
    # filename and silently overwrote each other. Evidence that can be
    # clobbered is not evidence, so never overwrite -- suffix instead.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = os.path.join(args.evidence_dir, f"llm_review_{short_sha}_{stamp}")
    out_path = f"{base}.json"
    dedupe = 2
    while os.path.exists(out_path):
        out_path = f"{base}-{dedupe}.json"
        dedupe += 1
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    if degraded:
        print(f"DEGRADED ({error_kind}): {error_detail}", file=sys.stderr)
        print("No LLM evidence produced. Human review path is unchanged.", file=sys.stderr)
    else:
        print(f"verdict={record['verdict']}  findings={len(record['findings'])}")
        print(f"summary: {record['summary']}")
        for finding in record["findings"]:
            print(f"  [{finding.get('severity')}] {finding.get('area')}: {finding.get('detail')}")

    print(f"inputs_digest={inputs_digest}")
    print(f"artifact={out_path}")

    # Deliberately independent of the verdict -- see review.sh's header.
    sys.exit(2 if degraded else 0)


if __name__ == "__main__":
    main()
