#!/usr/bin/env python3
"""Compare two dump-encode.c outputs and say WHERE they diverge, not just how much.

Written for the D-026 fourth addendum's open question: upstream's image encoder
differs across machines by `max |Δ|` 3.3-8.7, undiagnosed. A single max is not
enough to judge that number -- 8.71 is 5.2 sigma of this tensor's own value
distribution, which sounds alarming, but the tensor also holds a few values near
100. Whether the gap is benign turns on which of those it lands on.

So this prints the max alongside the magnitude of the value it landed on, the
relative error there, and the worst gap within the bulk of the distribution
separately from the worst among the outliers. A large absolute gap on a large
value is float reordering; a large gap on a typical value is a bug.

Usage: compare-dumps.py A.txt B.txt [label-a] [label-b]
Exit code is always 0: this reports, it does not gate.
"""

import sys


def read_dump(path):
    with open(path) as f:
        header = f.readline().split()
        n_tokens, n_embd = int(header[0]), int(header[1])
        values = [float(line) for line in f if line.strip()]
    if len(values) != n_tokens * n_embd:
        sys.exit(f"{path}: header says {n_tokens}x{n_embd} but file holds {len(values)}")
    return values, n_tokens, n_embd


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path_a, path_b = sys.argv[1], sys.argv[2]
    label_a = sys.argv[3] if len(sys.argv) > 3 else path_a
    label_b = sys.argv[4] if len(sys.argv) > 4 else path_b

    a, ta, ea = read_dump(path_a)
    b, tb, eb = read_dump(path_b)
    if (ta, ea) != (tb, eb):
        sys.exit(f"shape mismatch: {ta}x{ea} vs {tb}x{eb} -- not comparable")

    diffs = [abs(x - y) for x, y in zip(a, b)]
    max_abs = max(diffs)
    worst = diffs.index(max_abs)

    # Cosine, so a total-garbage result is distinguishable from a reordering.
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(y * y for y in b) ** 0.5
    cos = dot / (na * nb) if na and nb else float("nan")

    print(f"=== {label_a}")
    print(f"vs  {label_b}")
    print(f"    {ta} tokens x {ea} embd = {len(a)} values")
    print()
    print(f"max |Δ|        : {max_abs:.6f}  (at index {worst})")
    print(f"  the values there: {a[worst]:.6f} vs {b[worst]:.6f}")
    if abs(a[worst]) > 1e-9:
        print(f"  relative error  : {100 * max_abs / abs(a[worst]):.4f}%")
    print(f"cosine         : {cos:.9f}")
    print(f"exactly equal  : {sum(1 for d in diffs if d == 0.0)} / {len(a)} values")
    print()

    # The question the max alone cannot answer: does the gap track magnitude?
    # Split at |v| = 5 -- p1/p99 of this tensor sit at +-4.4, so "bulk" is the
    # typical value and "tail" is the handful of large ones.
    bulk = [(d, v) for d, v in zip(diffs, a) if abs(v) <= 5.0]
    tail = [(d, v) for d, v in zip(diffs, a) if abs(v) > 5.0]
    for name, group in (("bulk (|v| <= 5)", bulk), ("tail (|v| >  5)", tail)):
        if not group:
            print(f"{name}: empty")
            continue
        worst_d, worst_v = max(group, key=lambda p: p[0])
        rel = 100 * worst_d / abs(worst_v) if abs(worst_v) > 1e-9 else float("nan")
        print(f"{name}: {len(group):6d} values | worst |Δ| = {worst_d:.6f} on value {worst_v:.4f} ({rel:.3f}% relative)")

    # If the divergence is float reordering, the biggest gaps sit on the biggest
    # values. If it is a bug, they sit anywhere.
    top = sorted(zip(diffs, a), key=lambda p: -p[0])[:20]
    mean_top_mag = sum(abs(v) for _, v in top) / len(top)
    mean_all_mag = sum(abs(v) for v in a) / len(a)
    print()
    print(f"mean |value| under the 20 biggest gaps : {mean_top_mag:.4f}")
    print(f"mean |value| overall                   : {mean_all_mag:.4f}")
    if mean_all_mag > 0:
        print(f"ratio                                  : {mean_top_mag / mean_all_mag:.1f}x")
        print()
        print("A ratio >> 1 means the gaps land on the large values -- the signature of")
        print("float reordering. A ratio near 1 means they land anywhere, which reordering")
        print("does not explain.")


if __name__ == "__main__":
    main()
