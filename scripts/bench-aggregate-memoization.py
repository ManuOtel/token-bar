#!/usr/bin/env python3
"""Deterministic count-only measurement for the aggregate memoization slice.

Compares per-record pricing resolution (one resolve per record: catalog
lookup + static-table scan each time) against the memoized aggregate path
(one resolve per unique normalized model key per aggregate call) on the
same synthetic data. Deterministic resolve counts only, no wall-clock,
no timing thresholds (CI-safe on any host).

What it proves:
- repeated normalized models share one lookup result (case/whitespace
  variants collapse to the same key)
- aggregate cost matches independent per-record math across nil/fresh/cached
- resolve-call savings scale with repetition (records vs unique keys)

It does NOT claim a real-host speedup: to measure wall-clock, rerun warm
all-source aggregation before/after on the same Mac + same history.
Swift is unavailable on this worker host, so counts are the only claim.
"""

FALLBACK = (3.0, 12.0, 1.5)
PRICE_EXACT = {
    "github-copilot/gpt-5.6-sol": (1.25, 10.0, 0.125),
    "openai/gpt-5.6-luna": (1.25, 10.0, 0.125),
    "opencode-go/muse-spark-1.3-contributor": (3.0, 15.0, 0.30),
}
PRICE_TABLE = [
    ("gpt-4o-mini", (0.15, 0.60, 0.075)),
    ("gpt-4o", (2.50, 10.0, 1.25)),
    ("gpt-5-mini", (0.25, 2.0, 0.025)),
    ("gpt-5", (1.25, 10.0, 0.125)),
    ("o1-mini", (1.10, 4.40, 0.55)),
    ("o1", (15.0, 60.0, 7.50)),
    ("o3-mini", (1.10, 4.40, 0.55)),
    ("o3", (2.0, 8.0, 0.50)),
    ("claude-haiku", (0.80, 4.0, 0.08)),
    ("claude-sonnet", (3.0, 15.0, 0.30)),
    ("claude-opus", (15.0, 75.0, 1.50)),
    ("gemini-flash", (0.35, 1.05, 0.035)),
    ("gemini-pro", (1.25, 10.0, 0.125)),
]


def normalize_key(model):
    return (model or "").strip().lower()


def make_catalog():
    # Synthetic catalog: exact ids plus one shared bare suffix.
    return {
        normalize_key("openai/gpt-4o"): (9.0, 9.0, 9.0),
        normalize_key("a-provider/dup-model"): (5.0, 6.0, 0.5),
        normalize_key("b-provider/dup-model"): (111.0, 222.0, 33.0),
    }


def suffix_price(key, catalog):
    if "/" in key:
        return None
    suffixes = sorted(
        m for m in catalog if m.split("/")[-1] == key)
    if not suffixes:
        return None
    return catalog[suffixes[0]]


def resolve(model, catalog=None, counter=None):
    if counter is not None:
        counter[0] += 1
    key = normalize_key(model)
    if catalog is not None:
        if key in catalog:
            return catalog[key]
        hit = suffix_price(key, catalog)
        if hit is not None:
            return hit
    if key in PRICE_EXACT:
        return PRICE_EXACT[key]
    for match, price in PRICE_TABLE:
        if match in key:
            return price
    return FALLBACK


def cost_with_price(price, i, o, c):
    cached = min(max(0, c), max(0, i))
    fresh = max(0, i) - cached
    inp, outp, cch = price
    return fresh / 1e6 * inp + cached / 1e6 * cch + max(0, o) / 1e6 * outp


def main():
    catalog = make_catalog()
    models = [
        "openai/gpt-4o",
        "OPENAI/GPT-4O",
        "  openai/gpt-4o  ",
        "dup-model",
        "DUP-MODEL",
        "openai/gpt-5.6-luna",
        "gpt-5",
        "mystery-model-zzz",
    ]
    records = []
    for i in range(240):
        records.append({
            "model": models[i % len(models)],
            "input": 1000 + (i % 5) * 100,
            "output": 500,
            "cached": 5000 if i % 7 == 0 else 200,
        })
    unique_keys = {normalize_key(r["model"]) for r in records}

    for name, cat in (("nil", None), ("fresh", catalog), ("cached", catalog)):
        # Old path: one resolve per record.
        old_counter = [0]
        expected = 0.0
        for r in records:
            expected += cost_with_price(
                resolve(r["model"], cat, old_counter),
                r["input"], r["output"], r["cached"])
        assert old_counter[0] == len(records), "old path resolves per record"

        # New path: one resolve per unique normalized key, same math.
        new_counter = [0]
        cache = {}
        got = 0.0
        for r in records:
            key = normalize_key(r["model"])
            if key not in cache:
                cache[key] = resolve(r["model"], cat, new_counter)
            got += cost_with_price(
                cache[key], r["input"], r["output"], r["cached"])
        assert new_counter[0] == len(unique_keys), "new path resolves per key"
        assert abs(got - expected) < 1e-9, f"parity broke ({name})"
        saved = old_counter[0] - new_counter[0]
        print(f"snapshot={name}: records={len(records)} "
              f"unique_keys={len(unique_keys)} "
              f"resolves_old={old_counter[0]} resolves_new={new_counter[0]} "
              f"saved={saved} ({saved / old_counter[0]:.1%}) parity=OK")

    print("note: deterministic resolve counts only; no wall-clock claimed")
    print("bench-aggregate-memoization: OK (count-only, no wall-clock)")


if __name__ == "__main__":
    main()
