"""Address-generator readout with FOUR ct groups and padding on - the one
combination the single-group probe could not cover.

Input value encodes BOTH the group and the row/column:
    ch[g*8+0][h,w] = (h+1) + g*32      row    probe, group g
    ch[g*8+1][h,w] = (w+1) + g*32      column probe, group g
so a returned value v means group v//32 and row/col (v%32)-1. 0 means padding.
Weights are an identity: each output channel picks exactly one (group, tap)."""
import os, sys, numpy as np
T2  = "Task2"
VIV = "c:/RTL/Task_2_26_summer_CNN"
OUT = os.path.dirname(os.path.abspath(__file__))
sys.argv = [sys.argv[0]]
import quant_cnn as Q

ROW, COL, NB = Q.ROW_SIZE, Q.COL_SIZE, Q.NB_IN
H = W = 28; PAD = FH = FW = 3, ; PAD, FH, FW = 1, 3, 3
OH, OW = H + 2*PAD - FH + 1, W + 2*PAD - FW + 1
NCT   = 4
C_pad = NCT * ROW                                    # 32

x = np.zeros((C_pad, H, W), dtype=np.int64)
for g in range(NCT):
    x[g*ROW + 0] = np.arange(1, H+1)[:, None] + g*32          # row ramp
    x[g*ROW + 1] = np.arange(1, W+1)[None, :] + g*32          # col ramp

# output channel -> (ct, fh, fw, which lane). 4 groups x 8 probes = 32
PROBES = [((0,0), 0), ((0,1), 0), ((1,1), 0), ((2,2), 0),      # row  probes
          ((0,0), 1), ((1,1), 1),                              # col  probes
          ((2,0), 0), ((0,2), 0)]                              # row  probes
Wint = np.zeros((COL, C_pad, FH, FW), dtype=np.int64)
meta = {}
for p, ((fh, fw), lane) in enumerate(PROBES):
    for ct in range(NCT):
        fn = p*NCT + ct
        Wint[fn, ct*ROW + lane, fh, fw] = 1
        meta[fn] = (ct, fh, fw, "ROW" if lane == 0 else "COL")

xp  = np.pad(x, ((0,0),(PAD,PAD),(PAD,PAD)))
acc = np.zeros((COL, OH, OW), dtype=np.int64)
for i in range(FH):
    for j in range(FW):
        acc += np.einsum('fr,rhw->fhw', Wint[:, :, i, j], xp[:, i:i+OH, j:j+OW])
gold = np.clip(acc, 0, 127)

dram = np.zeros(Q.DRAM_DEPTH, dtype=np.int64)
bn = np.zeros(Q.BN_WORDS, dtype=np.int64)
for j in range(4): bn[1*4 + j] = 0x11111111          # group 1: A = 1 everywhere
dram[Q.BN_BASE:Q.BN_BASE+Q.BN_WORDS] = bn
act = Q.emit_activation(x, C_pad)
dram[Q.ACT_A:Q.ACT_A+act.size] = act
DBG_W = 0x9800
tiles = Q.emit_weight_tiles(Wint, C_pad, FH, FW)
dram[DBG_W:DBG_W+tiles.size] = tiles

e = dict(name="Conv1_2", pool=False, has_bn=True, s1=0, s2=0, M2=1, Wint=Wint,
         Aq=np.ones(COL, dtype=np.int64), Bq=np.zeros(COL, dtype=np.int64))
prog = Q.layer_csr(e, 1, H, W, OH, OW, C_pad, Q.ACT_A, Q.ACT_B,
                   H*W*(C_pad//ROW)*NB, OH*OW*(COL//ROW)*NB, H*W*NB, OH*OW*NB,
                   w_base=DBG_W, fh=FH, fw=FW, pad=PAD)
prog.append((0xE, 0)); pw = Q.csr_words(prog)
dram[Q.PROG_BASE:Q.PROG_BASE+pw.size] = pw

exp = Q.emit_activation(gold, COL)
def wr(fn, vals, w=8):
    with open(os.path.join(OUT, fn), "w") as f:
        f.write("\n".join(format(int(v) & (2**(4*w)-1), f'0{w}x') for v in vals) + "\n")
wr("dram.txt", dram); wr("gold.txt", list(exp))
wr("gold_addr.txt", list(range(Q.ACT_B, Q.ACT_B+exp.size)), w=4)
import shutil, json
for t in [os.path.join(VIV,"Task_1_26_summer.sim","sim_1","behav","xsim"),
          os.path.join(VIV,"Task_1_26_summer.ip_user_files","mem_init_files")]:
    for f in ("dram.txt","gold.txt","gold_addr.txt"):
        shutil.copy2(os.path.join(OUT,f), os.path.join(t,f))
np.save(os.path.join(OUT,"probe_gold.npy"), gold)
json.dump({str(k): v for k, v in meta.items()}, open(os.path.join(OUT,"probe_meta.json"),"w"))
print(f"probe4: {NCT} ct groups, {C_pad} channels, pad={PAD}, {exp.size} golden words")
print(f"  in_words={H*W*(C_pad//ROW)*NB}  ct_stride={H*W*NB}  weights {tiles.size} words")
