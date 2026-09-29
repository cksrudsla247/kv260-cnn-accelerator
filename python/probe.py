"""Read the address generator out directly.

Weights are an IDENTITY: output channel fn picks exactly one filter tap and one
input channel, weight 1, everything else 0. BN is A=1,B=0,s1=0,M2=1,s2=0, so the
output byte IS the accumulator, which IS the single input byte the hardware read.

  input ch0[h,w] = h+1     ch1[h,w] = w+1        (1..28, never 0)
  out fn=0..8   -> tap (fn/3, fn%3), reads ch0 : the byte's value is the ROW  it read
  out fn=9..17  -> tap (t/3, t%3),   reads ch1 : the value is the COLUMN it read

A correctly padded position reads nothing and must come out 0. Any nonzero there
names the row/column the hardware actually fetched."""
import os, sys, numpy as np
T2 = "Task2"
VIV = "c:/RTL/Task_2_26_summer_CNN"
OUT = os.path.dirname(os.path.abspath(__file__))
sys.argv = [sys.argv[0]]
import quant_cnn as Q

ROW, COL, NB = Q.ROW_SIZE, Q.COL_SIZE, Q.NB_IN
H = W = 28
PAD, FH, FW = 1, 3, 3
OH, OW = H + 2*PAD - FH + 1, W + 2*PAD - FW + 1      # 28, 28
C_pad = ROW                                          # one ct group

x = np.zeros((C_pad, H, W), dtype=np.int64)
x[0] = np.arange(1, H+1)[:, None] * np.ones((1, W), dtype=np.int64)   # h+1
x[1] = np.ones((H, 1), dtype=np.int64) * np.arange(1, W+1)[None, :]   # w+1

Wint = np.zeros((COL, C_pad, FH, FW), dtype=np.int64)
for fn in range(9):
    Wint[fn,     0, fn//3, fn%3] = 1                 # row probe
    Wint[fn + 9, 1, fn//3, fn%3] = 1                 # column probe

xp = np.pad(x, ((0,0),(PAD,PAD),(PAD,PAD)))
acc = np.zeros((COL, OH, OW), dtype=np.int64)
for i in range(FH):
    for j in range(FW):
        acc += np.einsum('fr,rhw->fhw', Wint[:, :, i, j], xp[:, i:i+OH, j:j+OW])
gold = np.clip(acc, 0, 127)                          # A=1,B=0,s1=0,M2=1,s2=0

dram = np.zeros(Q.DRAM_DEPTH, dtype=np.int64)
bn = np.zeros(Q.BN_WORDS, dtype=np.int64)
for j in range(4):
    bn[1*4 + j] = 0x11111111                         # group 1, A = 1 for all 32
dram[Q.BN_BASE:Q.BN_BASE+Q.BN_WORDS] = bn            # all B stay 0
dram[Q.ACT_A:Q.ACT_A+H*W*(C_pad//ROW)*NB] = Q.emit_activation(x, C_pad)
DBG_W = 0x9800
tiles = Q.emit_weight_tiles(Wint, C_pad, FH, FW)
dram[DBG_W:DBG_W+tiles.size] = tiles

e = dict(name="Conv1_2", pool=False, has_bn=True, s1=0, s2=0, M2=1,
         Wint=Wint, Aq=np.ones(COL, dtype=np.int64), Bq=np.zeros(COL, dtype=np.int64))
prog = Q.layer_csr(e, 1, H, W, OH, OW, C_pad, Q.ACT_A, Q.ACT_B,
                   H*W*(C_pad//ROW)*NB, OH*OW*(COL//ROW)*NB, H*W*NB, OH*OW*NB,
                   w_base=DBG_W, fh=FH, fw=FW, pad=PAD)
prog.append((0xE, 0))
pw = Q.csr_words(prog); dram[Q.PROG_BASE:Q.PROG_BASE+pw.size] = pw

exp = Q.emit_activation(gold, COL)
def wr(fn, vals, w=8):
    with open(os.path.join(OUT, fn), "w") as f:
        f.write("\n".join(format(int(v) & (2**(4*w)-1), f'0{w}x') for v in vals) + "\n")
wr("dram.txt", dram); wr("gold.txt", list(exp))
wr("gold_addr.txt", list(range(Q.ACT_B, Q.ACT_B + exp.size)), w=4)
import shutil
for t in [os.path.join(VIV,"Task_1_26_summer.sim","sim_1","behav","xsim"),
          os.path.join(VIV,"Task_1_26_summer.ip_user_files","mem_init_files")]:
    for f in ("dram.txt","gold.txt","gold_addr.txt"):
        shutil.copy2(os.path.join(OUT,f), os.path.join(t,f))
np.save(os.path.join(OUT,"probe_gold.npy"), gold)
print(f"probe: {OH}x{OW}x{COL}, {exp.size} golden words at 0x{Q.ACT_B:04X}")
print(f"  identity weights at 0x{DBG_W:04X} ({tiles.size} words, {FH*FW} tiles)")
print(f"  expected row-probe  fn=0 (tap 0,0): oh=0 and ow=0 are padding -> 0")
print(f"  gold[0,0,:4]={gold[0,0,:4]}  gold[0,1,:4]={gold[0,1,:4]}")
