"""Structure of a tb_top mismatch. Reads got.txt (addr got exp) and reports
WHERE the errors are, which is the diagnosis; the value differences are not."""
import sys, os
import numpy as np

ROW_SIZE, NB_IN = 8, 2
ACT_A, ACT_B = 0xB970, 0xD1F0

def load(fn):
    a, g, e = [], [], []
    for ln in open(fn):
        p = ln.split()
        if len(p) == 3:
            a.append(int(p[0], 16)); g.append(int(p[1], 16)); e.append(int(p[2], 16))
    return np.array(a), np.array(g, dtype=np.int64), np.array(e, dtype=np.int64)

def unpack(w):
    return np.stack([(w >> (8*k)) & 0xFF for k in range(4)], axis=-1)

def region(a, g, e, base, C, H, W, name):
    m = (a >= base) & (a < base + H*W*(C//ROW_SIZE)*NB_IN)
    if not m.any():
        return
    a2, g2, e2 = a[m], g[m], e[m]
    order = np.argsort(a2)
    g2, e2 = g2[order], e2[order]
    assert (a2[order] == np.arange(base, base + g2.size)).all(), "gaps in region"
    # (C/8, H, W, 8) group-major -> bytes
    gb = unpack(g2).reshape(C//ROW_SIZE, H, W, ROW_SIZE)
    eb = unpack(e2).reshape(C//ROW_SIZE, H, W, ROW_SIZE)
    bad = gb != eb
    print(f"\n===== {name} : {bad.sum()} / {bad.size} bytes wrong "
          f"({100.0*bad.sum()/bad.size:.1f}%) =====")

    print("\n  wrong bytes per output ROW (oh):")
    for h in range(H):
        n = bad[:, h].sum()
        bar = "#" * int(40.0 * n / max(1, bad[:, h].size))
        print(f"    oh={h:3d} {n:5d} {bar}")

    print("\n  wrong bytes per output COL (ow):")
    for w in range(W):
        n = bad[:, :, w].sum()
        bar = "#" * int(40.0 * n / max(1, bad[:, :, w].size))
        print(f"    ow={w:3d} {n:5d} {bar}")

    print("\n  wrong bytes per CHANNEL (c = grp*8 + lane):")
    for grp in range(C//ROW_SIZE):
        for lane in range(ROW_SIZE):
            n = bad[grp, :, :, lane].sum()
            tot = H*W
            print(f"    c={grp*ROW_SIZE+lane:3d} {n:5d}/{tot}", end="")
        print()

    # is the whole map simply shifted in space?
    print("\n  spatial shift test (does got[h,w] == exp[h+dh, w+dw] ?):")
    best = []
    for dh in (-2,-1,0,1,2):
        for dw in (-2,-1,0,1,2):
            gs = gb[:, max(0,-dh):H-max(0,dh), max(0,-dw):W-max(0,dw)]
            es = eb[:, max(0,dh):H-max(0,-dh), max(0,dw):W-max(0,-dw)]
            if gs.size == 0: continue
            best.append((100.0*(gs == es).mean(), dh, dw))
    for pct, dh, dw in sorted(best, reverse=True)[:5]:
        print(f"    dh={dh:+d} dw={dw:+d} : {pct:5.1f}% match")

    # is a channel permutation to blame?
    print("\n  channel permutation test (got channel i == exp channel j ?):")
    hits = 0
    for i in range(C):
        gi = gb[i//ROW_SIZE, :, :, i%ROW_SIZE]
        for j in range(C):
            ej = eb[j//ROW_SIZE, :, :, j%ROW_SIZE]
            if np.array_equal(gi, ej):
                if i != j:
                    print(f"    got c={i} == exp c={j}")
                hits += 1
                break
    print(f"    {hits}/{C} channels matched some expected channel")

if __name__ == "__main__":
    fn = sys.argv[1] if len(sys.argv) > 1 else "got.txt"
    a, g, e = load(fn)
    print(f"loaded {a.size} compared words from {fn}")
    region(a, g, e, ACT_A, 32, 28, 28, "Conv1_1 output @ACT_A")
    # the debug run turns pooling off, so the region is 28x28 not 14x14
    nb = ((a >= ACT_B) & (a < ACT_B + 6272)).sum()
    if nb >= 6272:
        region(a, g, e, ACT_B, 32, 28, 28, "Conv1_2 output @ACT_B (NOT pooled)")
    else:
        region(a, g, e, ACT_B, 32, 14, 14, "Conv1_2 output @ACT_B (pooled)")
