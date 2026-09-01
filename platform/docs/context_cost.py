#!/usr/bin/env python3
"""How many tokens does it cost an agent to read this platform's evidence?

WHY THIS EXISTS.

`headroom` (67,784 stars) claims 60-95% token reduction on JSON before it
reaches a model. This platform is managed with agent assistance and its
evidence is all JSON, so the claim, if it transferred, would decide how much
of the platform an agent can hold at once.

It does not transfer, and the number is the point of this script: measured
against THIS repository's evidence with the tokenizer of the model that
actually reads it, the reduction is ~32% over all files and ~38% over the
bundle an agent really opens -- not 60-95%. The published figure comes from
large, highly repetitive payloads; these files are small and heterogeneous.

The measurement is deterministic: a fixed file set, a fixed tokenizer, no
sampling and no temperature. Re-run it before re-deciding, rather than
re-estimating -- an estimate wearing a measurement's clothes is the thing the
decision records exist to prevent.
"""
import glob
import json
import os
import sys

# The model that actually reads this platform (CLAUDE.md: local MLX Qwen), so
# the count is in the units that matter rather than in bytes-over-four.
MODEL = "mlx-community/Qwen3.6-35B-A3B-4bit"


def find_tokenizer():
    hub = os.path.expanduser("~/.cache/huggingface/hub")
    pat = os.path.join(hub, "models--" + MODEL.replace("/", "--"),
                       "snapshots", "*", "tokenizer.json")
    hits = sorted(glob.glob(pat))
    return hits[-1] if hits else None


def columnar(o):
    """The one transformation that actually pays: an array of homogeneous
    objects restates every key on every row. Replace it with one key list and
    positional rows. Lossless and reversible -- no summarising, no dropping,
    because a digest that quietly discards a field is how an agent ends up
    confidently describing something that is not there."""
    if isinstance(o, list) and len(o) >= 3 and all(isinstance(x, dict) for x in o):
        keys = list(o[0].keys())
        if all(list(x.keys()) == keys for x in o):
            return {"__cols": keys,
                    "__rows": [[columnar(x[k]) for k in keys] for x in o]}
        return [columnar(x) for x in o]
    if isinstance(o, list):
        return [columnar(x) for x in o]
    if isinstance(o, dict):
        return {k: columnar(v) for k, v in o.items()}
    return o


def newest(pattern):
    hits = sorted(glob.glob(pattern))
    return hits[-1] if hits else None


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    os.chdir(root)

    tok_json = find_tokenizer()
    if not tok_json:
        sys.exit(f"REFUSING: no cached tokenizer for {MODEL}. Without it this "
                 "would count bytes and call them tokens, which is an estimate "
                 "dressed as a measurement.")
    try:
        from tokenizers import Tokenizer
    except ImportError:
        sys.exit("REFUSING: the `tokenizers` package is not importable by "
                 f"{sys.executable}. Run this through an interpreter that has "
                 "it; nothing is installed on your behalf.")
    tok = Tokenizer.from_file(tok_json)

    def n(text):
        return len(tok.encode(text).ids)

    files = [p for p in glob.glob("evidence/**/*.json", recursive=True)
             if "/_retired/" not in p]
    # The bundle an agent ACTUALLY opens to answer "what is the state of the
    # platform" -- not all of evidence/, which nobody reads and which is
    # therefore the wrong denominator for a context-budget claim.
    bundle = [p for p in [
        "docs/Stage-Report.json",
        "evidence/scheduler/dag_last.json",
        newest("evidence/observability/health_*.json"),
        newest("evidence/security/sast_summary_*.json"),
    ] if p and os.path.exists(p)]

    out = {"model": MODEL, "tokenizer": tok_json}
    for label, group in (("all_evidence", files), ("agent_bundle", bundle)):
        raw = dig = 0
        for path in group:
            try:
                text = open(path, encoding="utf-8").read()
                obj = json.loads(text)
            except Exception:  # noqa: BLE001
                continue
            raw += n(text)
            dig += n(json.dumps(columnar(obj), separators=(",", ":"),
                                ensure_ascii=False))
        out[label] = {"files": len(group), "raw_tokens": raw,
                      "digest_tokens": dig,
                      "reduction_pct": round(100 * (raw - dig) / raw, 1) if raw else 0}

    # The finding the reduction figure hides. 1,214 near-identical health
    # probes is not a verbosity problem that compression fixes; it is a file
    # COUNT problem, and no agent reads 1,214 files -- it reads two and
    # generalises, which is a grounding gap wearing the costume of evidence.
    counts = {}
    for path in files:
        counts[path.split("/")[1]] = counts.get(path.split("/")[1], 0) + 1
    out["files_by_dir"] = dict(sorted(counts.items(), key=lambda kv: -kv[1]))

    print(json.dumps(out, indent=2, ensure_ascii=False))
    b = out["agent_bundle"]
    print(f"\nagent bundle: {b['raw_tokens']:,} -> {b['digest_tokens']:,} tokens "
          f"(-{b['reduction_pct']}%), across {b['files']} files",
          file=sys.stderr)


if __name__ == "__main__":
    main()
