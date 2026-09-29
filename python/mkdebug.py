"""Isolation harness. Preloads Conv1_1's verified output into ACT_A and runs ONE
synthetic layer over it, so Conv1_1 is out of the picture and each feature of
Conv1_2 can be switched on separately.

  --taps center   fh=fw=1 only, pad 0   : ct loop + RMW + row streaming, no fh/fw
  --taps nopad    3x3, pad 0, 28x28 -> 26x26 : the (fh,fw) loop with NO padding
  --taps full     the real 3x3 pad 1    : everything (== Conv1_2)
  --ct N          use only the first N input-channel groups (default 4)
"""
import argparse, os, sys, numpy as np
ap = argparse.ArgumentParser()
ap.add_argument("--t2", default="Task2")
ap.add_argument("--taps", default="center", choices=["center","nopad","full"])
ap.add_argument("--ct", type=int, default=4)
ap.add_argument("--vivado", default="c:/RTL/Task_2_26_summer_CNN")
ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
args = ap.parse_args()
sys.argv = [sys.argv[0]]
import quant_cnn as Q

sys.path.insert(0, args.t2); sys.path.insert(0, os.path.join(args.t2, "04_CNN"))
from dataset.mnist import load_mnist
from convnet_hw import ConvNetHW
(_, _), (x_test, t_test) = load_mnist(flatten=False, one_hot_label=True)
net = ConvNetHW(output_size=10); net.load_params(os.path.join(args.t2, "params_hw.pkl"))
q, S_in = Q.build_quant(net, x_test[:200])
labels = np.argmax(t_test, axis=1); idx = 0
for i in range(200):
    if int(np.argmax(Q.infer_int(q, S_in, x_test[i:i+1])["Affine"])) == labels[i]:
        idx = i; break
outs = Q.infer_int(q, S_in, x_test[idx:idx+1])

ROW, COL, NB = Q.ROW_SIZE, Q.COL_SIZE, Q.NB_IN
x  = outs["Conv1_1"][0].astype(np.int64)          # (32,28,28), bit-exact in HW
e  = q["Conv1_2"]
Wq = e['Wint'].astype(np.int64)                   # (32,32,3,3)
H = W = 28
NCT = args.ct
C_pad = NCT * ROW

# The CSR has ONE pad field for both axes, so every mode keeps the sweep square.
#   center : 1 tap,  no padding          -> isolates the ct loop      (PASSED)
#   nopad  : 3x3,    no padding at all   -> the (fh,fw) loop, alone
#   full   : 3x3,    pad 1               -> everything, == Conv1_2
MODES = {"center": ([1], [1], 0),
         "nopad":  ([0,1,2], [0,1,2], 0),
         "full":   ([0,1,2], [0,1,2], 1)}
FHL, FWL, PAD = MODES[args.taps]
FH, FW = len(FHL), len(FWL)
OH = H + 2*PAD - FH + 1
OW = W + 2*PAD - FW + 1

# ---- golden
Wsub = Wq[:, :C_pad][:, :, FHL][:, :, :, FWL]     # (32, C_pad, FH, FW)
xs   = x[:C_pad]
xpad = np.pad(xs, ((0,0),(PAD,PAD),(PAD,PAD)))
acc  = np.zeros((COL, OH, OW), dtype=np.int64)
for ct in range(NCT):
    for i in range(FH):
        for j in range(FW):
            acc += np.einsum('fr,rhw->fhw',
                             Wsub[:, ct*ROW:(ct+1)*ROW, i, j],
                             xpad[ct*ROW:(ct+1)*ROW, i:i+OH, j:j+OW])
t = ((acc * e['Aq'][:, None, None]) >> e['s1']) + e['Bq'][:, None, None]
y = np.clip((t * e['M2']) >> e['s2'], 0, 127).astype(np.int64)

# ---- DRAM
dram = np.zeros(Q.DRAM_DEPTH, dtype=np.int64)
bn, ngrp = Q.emit_bn_table(q)
dram[Q.BN_BASE:Q.BN_BASE+Q.BN_WORDS] = bn
act = Q.emit_activation(x, 32)                    # Conv1_1 output, preloaded
dram[Q.ACT_A:Q.ACT_A+act.size] = act
DBG_W = 0x9800                                    # free: real table ends 0x9780
tiles = Q.emit_weight_tiles(Wsub, C_pad, FH, FW)
dram[DBG_W:DBG_W+tiles.size] = tiles

e2 = dict(e); e2['pool'] = False
prog = Q.layer_csr(e2, 1, H, W, OH, OW, C_pad, Q.ACT_A, Q.ACT_B,
                   H*W*NCT*NB, OH*OW*(COL//ROW)*NB, H*W*NB, OH*OW*NB,
                   w_base=DBG_W, fh=FH, fw=FW, pad=PAD)
prog.append((0xE, 0))
pw = Q.csr_words(prog)
dram[Q.PROG_BASE:Q.PROG_BASE+pw.size] = pw

exp = Q.emit_activation(y, COL)
gold_a = list(range(Q.ACT_B, Q.ACT_B + exp.size))

def wr(fn, vals, w=8):
    with open(os.path.join(args.out, fn), "w") as f:
        f.write("\n".join(format(int(v) & (2**(4*w)-1), f'0{w}x') for v in vals) + "\n")
    return len(vals)
wr("dram.txt", dram); wr("gold.txt", list(exp)); wr("gold_addr.txt", gold_a, w=4)
import shutil
for tdir in [os.path.join(args.vivado, "Task_1_26_summer.sim","sim_1","behav","xsim"),
             os.path.join(args.vivado, "Task_1_26_summer.ip_user_files","mem_init_files")]:
    os.makedirs(tdir, exist_ok=True)
    for fn in ("dram.txt","gold.txt","gold_addr.txt"):
        shutil.copy2(os.path.join(args.out, fn), os.path.join(tdir, fn))

print(f"debug layer: taps={args.taps}  ct groups={NCT}  FH={FH} FW={FW} pad={PAD}")
print(f"  in  ACT_A 0x{Q.ACT_A:04X} ({H}x{W}, {C_pad} ch, preloaded Conv1_1 output)")
print(f"  W   0x{DBG_W:04X}  {tiles.size} words = {NCT*FH*FW} tiles")
print(f"  out ACT_B 0x{Q.ACT_B:04X}  {OH}x{OW}x{COL} -> {exp.size} golden words")
