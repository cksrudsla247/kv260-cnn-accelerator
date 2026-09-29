# coding: utf-8
"""
quant_cnn.py -- quantise the trained CNN and emit everything tb_top.v reads.

Outputs, into the directory given by --out (default: this file's directory):

    dram.txt        the whole DRAM image, one 8-hex-digit word per line
    gold.txt        expected output words
    gold_addr.txt   their DRAM addresses
    quant.json      the quantisation parameters, for reference

The trained network lives at  <T2>/params_hw.pkl  and must NOT be retrained;
run_hw.py would overwrite it and invalidate every golden value.

CONTRACTS THIS FILE MUST HONOUR  (see docs/DESIGN_NOTES.md sections 6, 7 and 15)

  weight tile      (ft, ct, fh, fw) with fw fastest; one tile is 64 words,
                   word 8r+b byte j = W[fn = 4b+j][c = ct*8+r][fh][fw]
  activations      (C/ROW_SIZE, H, W, ROW_SIZE), channel-group major
  BN table         432 words : 48 A-words (8 channels of 4 bits each) then
                   384 B-words (one 20-bit offset each)
  CSR program      word pairs (addr, data); 0xF starts a layer and waits,
                   0xE ends the program
  BN shift s1      per layer, CSR8[14:13].  NOT the fixed 2 the MLP used.

A mismatch in any of these is a bit-exact failure with a normal-looking
waveform, so each emitter is checked against a reference read-back below.
"""
import os, sys, json, argparse
import numpy as np

# ----------------------------------------------------------------- hardware
ROW_SIZE, COL_SIZE = 8, 32
NB_IN              = ROW_SIZE * 8 // 32        # 2
NB_OUT             = COL_SIZE * 8 // 32        # 8
TILE_WORDS         = ROW_SIZE * NB_OUT         # 64
GRP_PER_TILE       = COL_SIZE // ROW_SIZE      # 4
A_W, B_W, M_W      = 4, 20, 4
ACC_W              = 24
ALIM, WLIM         = 127, 127
MLIM               = 2**(A_W-1) - 1            # 7
BLIM               = 2**(B_W-1) - 1
EPS                = 1e-7

# DRAM map. BN_BASE and PROG_BASE are localparams in controller.v / tester.v
# and cannot be moved from here.
W_BASE, BN_BASE  = 0x0000, 0xAB80
IM2COL_BASE      = 0xAD30
ACT_A, ACT_B     = 0xB970, 0xD1F0
OUT_BASE         = 0xEA70
PROG_BASE        = 0xEA80
DRAM_DEPTH       = 65536
BN_WORDS         = 432

# Accelerator layers: name, pkl index, math pad, pool after, BN?, then the
# geometry the HARDWARE sees. Those differ for Conv1_1: Python im2col has
# already flattened the 3x3 window into 16 lanes and pre-filled the conv
# padding, so the hardware runs it as a 1x1 convolution with pad 0 and can
# never raise oob. Deriving hw_fh from has_bn instead produced fh_max=2 and
# pad=1 in the CSR word, which is silently wrong.
#                 name       L pad pool bn    hw_fh hw_fw hw_pad
LAYERS_FULL = [("Conv1_1",   1, 1, False, True,   1,    1,     0),
               ("Conv1_2",   2, 1, True,  True,   3,    3,     1),
               ("Conv2_1",   3, 1, False, True,   3,    3,     1),
               ("Conv2_2",   4, 1, True,  True,   3,    3,     1),
               ("Conv3",     5, 0, True,  True,   3,    3,     0),
               ("Affine",    6, 0, False, False,  1,    1,     0)]
LAYERS = [t[:5] for t in LAYERS_FULL]
HW_GEOM = {t[0]: dict(fh=t[5], fw=t[6], pad=t[7]) for t in LAYERS_FULL}


# ============================================================ quantisation
def build_quant(net, x_cal):
    """Per-layer INT8 weights, BN (A,B,s1) and requant (M2,s2)."""
    P = net.params

    def bn_ab(L):
        g, b = P[f'gamma{L}'], P[f'beta{L}']
        mu = net.layers[f'BatchNorm{L}'].running_mean
        vr = net.layers[f'BatchNorm{L}'].running_var
        a  = g / np.sqrt(vr + EPS)
        off = b - a * mu + a * P[f'b{L}']       # conv bias folds into the offset
        dead = vr < 1e-3                        # a channel that never fires
        a, off = a.copy(), off.copy()
        a[dead], off[dead] = 1.0, 0.0
        return a, off

    # activation ranges, from a float pass. acts[i] is what LAYERS[i] consumes.
    x = x_cal
    acts = [x]
    for key, layer in net.layers.items():
        x = layer.forward(x, False) if key.startswith('BatchNorm') else layer.forward(x)
        if key.startswith('Relu') and f'Pool{key[-1]}' not in net.layers:
            acts.append(x)
        if key.startswith('Pool'):
            acts.append(x)
    S_in = [a.max() / ALIM + 1e-12 for a in acts]

    q = {}
    for i, (name, L, pad, pool, has_bn) in enumerate(LAYERS):
        W = P[f'W{L}']
        if L == 6:
            W = W.T                             # (512,10) -> (FN=10, C=512)
        Sw   = np.abs(W).max() / WLIM
        Wint = np.clip(np.round(W / Sw), -WLIM, WLIM).astype(np.int64)

        e = dict(name=name, L=L, pad=pad, pool=pool, has_bn=has_bn,
                 Sw=Sw, Wint=Wint, S_in=S_in[i])
        if has_bn:
            a, off = bn_ab(L)
            # keep as much of `a` as the 4-bit field allows
            s1 = max((A_W - 1) - int(np.ceil(np.log2(np.abs(a).max()))), 0)
            e['s1'] = s1
            e['Aq'] = np.clip(np.round(a * 2.0**s1), -MLIM-1, MLIM).astype(np.int64)
            e['Bq'] = np.clip(np.round(off / (S_in[i] * Sw)), -BLIM-1, BLIM).astype(np.int64)
            Sc = S_in[i] * Sw / S_in[i+1]
            s2 = max((M_W - 1) - int(np.ceil(np.log2(Sc))), 0)
            e['s2'], e['M2'] = s2, int(np.clip(np.round(Sc * 2.0**s2), -MLIM-1, MLIM))
        q[name] = e
    return q, S_in


# ================================================= integer reference model
def im2col_int(x, FH, FW, pad):
    N, C, H, W = x.shape
    OH, OW = H + 2*pad - FH + 1, W + 2*pad - FW + 1
    xp = np.pad(x, ((0,0),(0,0),(pad,pad),(pad,pad)))
    col = np.zeros((N, C, FH, FW, OH, OW), dtype=np.int64)
    for i in range(FH):
        for j in range(FW):
            col[:, :, i, j] = xp[:, :, i:i+OH, j:j+OW]
    return col.transpose(0,4,5,1,2,3).reshape(N*OH*OW, -1), OH, OW


def maxpool_int(x):
    N, C, H, W = x.shape
    OH, OW = H//2, W//2                          # floor : 5 -> 2, 7 -> 3
    v = x[:, :, :OH*2, :OW*2].reshape(N, C, OH, 2, OW, 2)
    return v.max(axis=(3,5))


def infer_int(q, S_in, img, upto=None):
    """Integer inference, arithmetic identical to the RTL. Returns every
    accelerator layer's INT8 output (and the Affine logits)."""
    x = np.clip(np.round(img / S_in[0]), 0, ALIM).astype(np.int64)
    outs = {}
    for name, L, pad, pool, has_bn in LAYERS:
        e = q[name]
        if not has_bn:                           # Affine : wide 32-bit logits
            acc = x.reshape(x.shape[0], -1) @ e['Wint'].T
            outs[name] = acc
            break
        col, OH, OW = im2col_int(x, 3, 3, pad)
        acc = col @ e['Wint'].reshape(e['Wint'].shape[0], -1).T
        t   = ((acc * e['Aq']) >> e['s1']) + e['Bq']
        y   = np.clip((t * e['M2']) >> e['s2'], 0, ALIM).astype(np.int64)
        y   = y.reshape(x.shape[0], OH, OW, -1).transpose(0, 3, 1, 2)
        outs[name + "_prepool"] = y[0]           # for --debug-nopool
        if pool:
            y = maxpool_int(y)
        outs[name] = y
        x = y
        if name == upto:
            break
    return outs


# ============================================================== emitters
def pack_bytes_to_words(b):
    """Little-endian: byte 0 goes in the LSB, matching bank_unpack lane 0."""
    b = np.asarray(b, dtype=np.int64) & 0xFF
    assert b.size % 4 == 0
    b = b.reshape(-1, 4)
    return (b[:,0] | (b[:,1] << 8) | (b[:,2] << 16) | (b[:,3] << 24)).astype(np.int64)


def emit_weight_tiles(Wint, C_pad, FH, FW):
    """(ft, ct, fh, fw), fw fastest. Word 8r+b byte j = W[4b+j][ct*8+r][fh][fw].
    Wint is (FN, C, FH, FW); C is zero-padded to C_pad and FN to a multiple
    of COL_SIZE."""
    FN = Wint.shape[0]
    FN_pad = -(-FN // COL_SIZE) * COL_SIZE
    Wp = np.zeros((FN_pad, C_pad, FH, FW), dtype=np.int64)
    Wp[:FN, :Wint.shape[1]] = Wint
    words = []
    for ft in range(FN_pad // COL_SIZE):
        for ct in range(C_pad // ROW_SIZE):
            for fh in range(FH):
                for fw in range(FW):
                    for r in range(ROW_SIZE):
                        row = Wp[ft*COL_SIZE:(ft+1)*COL_SIZE, ct*ROW_SIZE + r, fh, fw]
                        words.extend(pack_bytes_to_words(row))
    return np.array(words, dtype=np.int64)


def emit_activation(x, C_pad):
    """(C/ROW_SIZE, H, W, ROW_SIZE) channel-group major, one image."""
    C, H, W = x.shape
    xp = np.zeros((C_pad, H, W), dtype=np.int64)
    xp[:C] = x
    g = xp.reshape(C_pad // ROW_SIZE, ROW_SIZE, H, W).transpose(0, 2, 3, 1)
    return pack_bytes_to_words(g.reshape(-1))


def emit_im2col(img_q):
    """Conv1_1's input: each 3x3 window flattened to 16 lanes, so the hardware
    sees a 1x1 convolution over a 16-channel map. Group-major like any other
    activation: all 784 pixels of taps 0..7, then all 784 of tap 8."""
    H = W = 28
    p = np.pad(img_q[0, 0], ((1,1),(1,1)))               # conv padding, in Python
    lanes = np.zeros((16, H, W), dtype=np.int64)
    for k in range(9):
        lanes[k] = p[k//3 : k//3 + H, k%3 : k%3 + W]     # taps row-major
    return emit_activation(lanes, 16)


def emit_bn_table(q):
    """432 words. A: waddr = grp*4 + j, nibble k -> channel 8j+k.
    B: waddr = 48 + grp*32 + lane."""
    words = np.zeros(BN_WORDS, dtype=np.int64)
    grp = 0
    for name, L, pad, pool, has_bn in LAYERS:
        if not has_bn:
            continue
        e = q[name]
        A, B = e['Aq'], e['Bq']
        FN = A.size
        for g in range(-(-FN // COL_SIZE)):
            for j in range(GRP_PER_TILE):
                w = 0
                for k in range(ROW_SIZE):
                    ch = g*COL_SIZE + j*ROW_SIZE + k
                    v  = int(A[ch]) if ch < FN else 0
                    w |= (v & 0xF) << (k * A_W)
                words[(grp+g)*GRP_PER_TILE + j] = w
            for lane in range(COL_SIZE):
                ch = g*COL_SIZE + lane
                v  = int(B[ch]) if ch < FN else 0
                words[48 + (grp+g)*COL_SIZE + lane] = v & 0xFFFFF
        grp += -(-FN // COL_SIZE)
    return words, grp


def csr_words(cfg):
    """word pairs (addr, data). 0xF = start and wait, 0xE = end of program."""
    out = []
    for addr, data in cfg:
        out += [addr & 0xF, data & 0xFFFFFFFF]
    return np.array(out, dtype=np.int64)


def layer_csr(e, bn_grp, H, W, OH, OW, C_pad, in_base, out_base,
              in_words, out_words, ct_stride, og_stride, w_base=None,
              fh=None, fw=None, pad=None):
    g = dict(HW_GEOM[e['name']])
    if fh  is not None: g['fh']  = fh
    if fw  is not None: g['fw']  = fw
    if pad is not None: g['pad'] = pad
    if w_base is None:  w_base = W_BASE
    ct_max = C_pad // ROW_SIZE - 1
    FN     = e['Wint'].shape[0]
    ft_max = -(-FN // COL_SIZE) - 1
    fh_max, fw_max = g['fh'] - 1, g['fw'] - 1
    cfg0 = ((ct_max & 0xFF)
            | ((fh_max & 3) << 8) | ((fw_max & 3) << 10)
            | ((ft_max & 0xF) << 12)
            | ((1 if e['pool'] else 0) << 16)
            | ((1 if e['has_bn'] else 0) << 17)
            | ((1 if e['has_bn'] else 0) << 18)      # relu with bn
            | ((0 if e['has_bn'] else 1) << 19)      # wide_out on the Affine
            | ((g['pad'] & 3) << 20))
    cfg1 = ((H-1) & 0xFF) | (((W-1) & 0xFF) << 8) \
           | (((OH-1) & 0xFF) << 16) | (((OW-1) & 0xFF) << 24)
    post = ((e.get('s2', 0) & 0xF)
            | ((e.get('M2', 0) & 0xF) << 4)
            | ((bn_grp & 0x1F) << 8)
            | ((e.get('s1', 0) & 3) << 13))
    stride = (ct_stride & 0xFFFF) | ((og_stride & 0xFFFF) << 16)
    return [(0, cfg0), (1, cfg1), (2, in_base), (3, in_words),
            (4, w_base), (5, out_base), (6, out_words), (8, post),
            (9, stride), (0xF, 1)]


# ==================================================================== main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--t2", default=os.environ.get("T2_DIR"),
                    help='a clone of mnist-cnn-from-scratch (holds params_hw.pkl and 04_CNN/)')
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--img", type=int, default=-1,
                    help="test image index; -1 picks the first one the "
                         "integer model gets right")
    ap.add_argument("--upto", default="Conv1_1",
                    help="last layer to put in the CSR program")
    ap.add_argument("--ncal", type=int, default=200)
    ap.add_argument("--debug-nopool", action="store_true",
                    help="force pool_en=0 on the LAST layer and check its "
                         "un-pooled map. Separates a reduction bug from a "
                         "maxpool/drain bug, and the result is invertible "
                         "back to accumulator values.")
    ap.add_argument("--vivado", default=None, metavar="PROJ_DIR",
                    help="also drop the three txt files where xsim will find "
                         "them, and overwrite the stale Task-1 copies staged in "
                         "ip_user_files/mem_init_files")
    args = ap.parse_args()

    sys.path.insert(0, args.t2)
    sys.path.insert(0, os.path.join(args.t2, "04_CNN"))
    from dataset.mnist import load_mnist
    from convnet_hw import ConvNetHW

    (_, _), (x_test, t_test) = load_mnist(flatten=False, one_hot_label=True)
    labels = np.argmax(t_test, axis=1)

    net = ConvNetHW(output_size=10)
    net.load_params(os.path.join(args.t2, "params_hw.pkl"))

    q, S_in = build_quant(net, x_test[:args.ncal])

    print("=" * 74)
    print("  layer     s1  s2  M2   A range     B range              Sw")
    print("-" * 74)
    for name, L, pad, pool, has_bn in LAYERS:
        e = q[name]
        if has_bn:
            print(f"  {name:8s} {e['s1']:3d} {e['s2']:3d} {e['M2']:3d}   "
                  f"[{e['Aq'].min():2d},{e['Aq'].max():2d}]    "
                  f"[{e['Bq'].min():8d},{e['Bq'].max():8d}]  {e['Sw']:.3e}")
        else:
            print(f"  {name:8s}   -   -   -   (no BN, 32-bit logits)      "
                  f"        {e['Sw']:.3e}")
    print("=" * 74)

    # pick an image the integer model classifies correctly
    idx = args.img
    if idx < 0:
        for i in range(200):
            lg = infer_int(q, S_in, x_test[i:i+1])["Affine"]
            if int(np.argmax(lg)) == labels[i]:
                idx = i
                break
    outs = infer_int(q, S_in, x_test[idx:idx+1])
    pred = int(np.argmax(outs["Affine"]))
    print(f"  test image {idx}, label {labels[idx]}, integer prediction {pred}"
          f"  {'OK' if pred == labels[idx] else 'MISMATCH'}")

    # -------------------------------------------------- assemble the DRAM
    dram = np.zeros(DRAM_DEPTH, dtype=np.int64)

    wp = W_BASE
    wptr = {}
    for name, L, pad, pool, has_bn in LAYERS:
        e = q[name]
        C_pad = -(-e['Wint'].shape[1] // ROW_SIZE) * ROW_SIZE
        if name == "Conv1_1":
            C_pad = 16                            # im2col: 9 taps -> 2 groups
            Wi = np.zeros((32, 16, 1, 1), dtype=np.int64)
            for k in range(9):
                Wi[:, k, 0, 0] = e['Wint'][:, 0, k//3, k%3]
            tiles = emit_weight_tiles(Wi, 16, 1, 1)
        elif name == "Affine":
            # permute the reduction axis into the hardware's read order:
            # byte ct*32 + (h*2+w)*8 + cl  holds channel ct*8+cl at (h,w),
            # while W6 is indexed by the numpy flatten order c*4 + h*2 + w
            Cn, Hn, Wn = 128, 2, 2
            perm = np.empty(Cn*Hn*Wn, dtype=np.int64)
            k = 0
            for ct in range(Cn // ROW_SIZE):
                for h in range(Hn):
                    for w in range(Wn):
                        for cl in range(ROW_SIZE):
                            perm[k] = (ct*ROW_SIZE + cl)*Hn*Wn + h*Wn + w
                            k += 1
            Wi = e['Wint'][:, perm][:, :, None, None]
            C_pad = Cn*Hn*Wn
            tiles = emit_weight_tiles(Wi, C_pad, 1, 1)
        else:
            tiles = emit_weight_tiles(e['Wint'][:, :, :, :], C_pad, 3, 3)
        wptr[name] = wp
        dram[wp:wp+tiles.size] = tiles
        wp += tiles.size
        e['C_pad'] = C_pad
    print(f"  weight table : {wp - W_BASE} words, ends 0x{wp:04X}")
    assert wp <= BN_BASE, "weight table runs into the BN table"

    bn, ngrp = emit_bn_table(q)
    dram[BN_BASE:BN_BASE+BN_WORDS] = bn
    print(f"  BN table     : {BN_WORDS} words at 0x{BN_BASE:04X}, {ngrp} groups")

    img_q = np.clip(np.round(x_test[idx:idx+1] / S_in[0]), 0, ALIM).astype(np.int64)
    im2 = emit_im2col(img_q)
    dram[IM2COL_BASE:IM2COL_BASE+im2.size] = im2
    print(f"  Conv1_1 input: {im2.size} words at 0x{IM2COL_BASE:04X}")

    # -------------------------------------------------- CSR program
    # One pass over the layers in order, up to --upto. Geometry is derived,
    # not tabulated: the HARDWARE fh/pad give the conv output size, pooling
    # halves it, and that is the next layer's input size. Deriving it means a
    # layer cannot silently disagree with the weight tiles emitted above.
    ORDER = [t[0] for t in LAYERS_FULL]
    if args.upto not in ORDER:
        raise SystemExit(f"--upto must be one of {ORDER}")
    n_layers = ORDER.index(args.upto) + 1

    prog = []
    exp_csr0 = []
    exp_w = []
    # out_base -> (name, expected words). A later layer writing the same base
    # replaces the entry, which is exactly what the A/B ping-pong does to the
    # layer before last. Only surviving regions can be checked at end of run.
    live = {}
    bn_grp = 0
    H = W  = 28
    in_base = IM2COL_BASE

    print("-" * 74)
    print("  layer     C_pad  FN   H,W    OH,OW   pool   OH',OW'  in@    out@   grp")
    print("-" * 74)

    for li in range(n_layers):
        name   = ORDER[li]
        e      = q[name]
        g      = HW_GEOM[name]
        C_pad  = e['C_pad']
        FN     = e['Wint'].shape[0]
        FN_pad = -(-FN // COL_SIZE) * COL_SIZE

        wide = not e['has_bn']
        last = (li == n_layers - 1)
        if last and args.debug_nopool and not wide:
            e = dict(e); e['pool'] = False       # local copy: the CSR0 bit and
            q[name] = e                          # the golden must agree
        if wide:
            # The Affine collapses to H=W=OH=OW=1 with the whole 2x2x128 map on
            # the reduction axis, and wide_out changes the drain: ONE burst at
            # out_base, then ST_CHUNK_END goes straight to ST_DONE. core.v emits
            # NB_OUT 32-bit logits per obuf row and wide_half_sel picks lanes
            # 0..7 or 8..15, so the drain writes 2 rows = 16 words and only the
            # first 16 output channels exist at all. 10 logits fit, and that is
            # where the DRAM map's 16-word output region comes from.
            H = W = OH = OW = 1
            out_base  = OUT_BASE
            out_words = 2 * NB_OUT
            og_stride = NB_IN
        else:
            OH = H + 2*g['pad'] - g['fh'] + 1
            OW = W + 2*g['pad'] - g['fw'] + 1
            assert OH > 0 and OW > 0, f"{name}: empty output map"
            out_base  = ACT_A if (li % 2 == 0) else ACT_B
            oh_p = OH // 2 if e['pool'] else OH
            ow_p = OW // 2 if e['pool'] else OW
            out_words = oh_p * ow_p * (FN_pad // ROW_SIZE) * NB_IN
            og_stride = oh_p * ow_p * NB_IN
        OHp, OWp = (OH // 2, OW // 2) if e['pool'] else (OH, OW)
        assert not (wide and FN_pad > 32), f"{name}: wide_out reaches 16 channels"

        in_words  = H * W * (C_pad // ROW_SIZE) * NB_IN
        ct_stride = H * W * NB_IN

        # every CSR field that indexes DRAM or counts iterations, against its
        # own width. docs/DESIGN_NOTES.md section 12: silent truncation has bitten this
        # project twice and both times was invisible in simulation.
        assert C_pad // ROW_SIZE - 1 <= 0xFF, f"{name}: ct_max overflows 8 bits"
        assert FN_pad // COL_SIZE - 1 <= 0xF, f"{name}: ft_max overflows 4 bits"
        for lbl, v in (("H", H), ("W", W), ("OH", OH), ("OW", OW)):
            assert 1 <= v <= 256, f"{name}: {lbl}={v} overflows the 8-bit field"
        assert max(in_words, out_words) < (1 << 13), f"{name}: words > LEN_W"
        assert max(ct_stride, og_stride) <= 0xFFFF, f"{name}: stride > 16 bits"
        assert out_base + out_words <= DRAM_DEPTH, f"{name}: output past DRAM"

        # wptr[name], NOT W_BASE. Conv1_1 sits at 0x0000 so passing the table
        # base happened to be right for it and wrong for every later layer,
        # which is the worst possible way for this to fail.
        prog += layer_csr(e, bn_grp, H, W, OH, OW, C_pad,
                          in_base, out_base, in_words, out_words,
                          ct_stride, og_stride, w_base=wptr[name])
        exp_w.append((name, wptr[name]))
        exp_csr0.append((name, dict(
            ct_max=C_pad // ROW_SIZE - 1,
            fh_max=g['fh'] - 1, fw_max=g['fw'] - 1,
            ft_max=FN_pad // COL_SIZE - 1,
            pool=1 if e['pool'] else 0,
            bn=0 if wide else 1, relu=0 if wide else 1, wide=1 if wide else 0,
            pad=g['pad'])))

        if wide:
            lg = np.asarray(outs[name]).reshape(-1)
            assert (np.abs(lg) < (1 << (ACC_W - 1))).all(),                 f"{name}: a logit does not fit ACCUM_WIDTH"
            exp = np.zeros(out_words, dtype=np.int64)
            exp[:lg.size] = lg           # obuf row 0 = ch 0..7, row 1 = ch 8..15
            exp &= 0xFFFFFFFF
        elif last and args.debug_nopool:
            live.clear()                 # 2 x 6272 would overrun tb_top's GMAX
            exp = emit_activation(outs[name + "_prepool"], FN_pad)
        else:
            exp = emit_activation(outs[name][0], FN_pad)
        assert exp.size == out_words,             f"{name}: golden {exp.size} words but CSR6 says {out_words}"
        live[out_base] = (name, exp)

        print(f"  {name:9s} {C_pad:4d} {FN:5d}  {H:2d},{W:2d}  {OH:3d},{OW:3d}"
              f"   {int(e['pool'])}    {OHp:3d},{OWp:3d}  "
              f"0x{in_base:04X} 0x{out_base:04X} {bn_grp:4d}")

        bn_grp += FN_pad // COL_SIZE
        in_base = out_base
        H, W = OHp, OWp

    gold_a, gold_w = [], []
    for base in sorted(live):
        name, exp = live[base]
        gold_a += list(range(base, base + exp.size))
        gold_w += list(exp)
        print(f"  golden : {name:9s} {exp.size:5d} words at 0x{base:04X}")
    # tb_top sizes its golden arrays at GMAX and $readmemh would quietly stop
    # there, reporting a pass on a partial check.
    assert len(gold_w) <= 8192,         f"golden {len(gold_w)} words exceeds tb_top GMAX=8192; raise it"

    prog.append((0xE, 0))
    pw = csr_words(prog)
    dram[PROG_BASE:PROG_BASE+pw.size] = pw
    print(f"  CSR program  : {pw.size} words at 0x{PROG_BASE:04X}")

    # ---- decode the program back out of the DRAM image and check it --------
    # The CSR word packing is the one place where a wrong bit is invisible in
    # simulation: the layer just computes something else. So read it back.
    print("-" * 74)
    print("  CSR readback")
    i = PROG_BASE
    while True:
        a, d = int(dram[i]) & 0xF, int(dram[i+1]); i += 2
        if a == 0xE:
            print("    0xE  end of program"); break
        if a == 0xF:
            print("    0xF  start, wait for done"); continue
        if a == 0:
            print(f"    CSR0 ct_max {d & 0xFF}  fh_max {(d>>8)&3}  fw_max {(d>>10)&3}"
                  f"  ft_max {(d>>12)&0xF}  pool {(d>>16)&1}  bn {(d>>17)&1}"
                  f"  relu {(d>>18)&1}  wide {(d>>19)&1}  pad {(d>>20)&3}")
        elif a == 1:
            print(f"    CSR1 H {(d & 0xFF)+1}  W {((d>>8)&0xFF)+1}"
                  f"  OH {((d>>16)&0xFF)+1}  OW {((d>>24)&0xFF)+1}")
        elif a == 8:
            print(f"    CSR8 rq_shift {d & 0xF}  rq_mult {(d>>4)&0xF}"
                  f"  bn_group {(d>>8)&0x1F}  bn_shift {(d>>13)&3}")
        elif a == 9:
            print(f"    CSR9 ct_stride {d & 0xFFFF}  og_stride {(d>>16)&0xFFFF}")
        else:
            print(f"    CSR{a} 0x{d:08X} ({d})")

    # every layer's CSR0, read back out of the DRAM image. A wrong bit here is
    # invisible in simulation - the layer just computes something else.
    # Split the program at each 0xF (start) so a layer's registers are checked
    # against THAT layer, then verify CSR0 and CSR4. A wrong weight base is
    # invisible in simulation - the layer just multiplies by another layer's
    # numbers - so it gets the same readback treatment as the packed CSR0.
    layers_rb, cur, k = [], {}, PROG_BASE
    while True:
        a, d = int(dram[k]) & 0xF, int(dram[k+1]); k += 2
        if a == 0xE: break
        if a == 0xF: layers_rb.append(cur); cur = {}
        else:        cur[a] = d
    assert len(layers_rb) == len(exp_csr0), "program has %d layers, expected %d" % (
        len(layers_rb), len(exp_csr0))
    for rb, (name, exp0), (_, expw) in zip(layers_rb, exp_csr0, exp_w):
        assert rb[4] == expw, ("CSR4 wrong for %s: weights are at 0x%04X but the "
                               "program says 0x%04X" % (name, expw, rb[4]))
        d0 = rb[0]
        got0 = dict(ct_max=d0 & 0xFF, fh_max=(d0>>8)&3, fw_max=(d0>>10)&3,
                    ft_max=(d0>>12)&0xF, pool=(d0>>16)&1, bn=(d0>>17)&1,
                    relu=(d0>>18)&1, wide=(d0>>19)&1, pad=(d0>>20)&3)
        assert got0 == exp0, "CSR0 wrong for %s: exp %s got %s" % (name, exp0, got0)
    print(f"    ok : CSR0 and CSR4 match the expected encoding for all "
          f"{len(exp_csr0)} layer(s)")

    # -------------------------------------------------- write the files
    def wr(fn, vals, w=8):
        with open(os.path.join(args.out, fn), "w") as f:
            f.write("\n".join(format(int(v) & (2**(4*w)-1), f'0{w}x') for v in vals))
            f.write("\n")
        return len(vals)

    n1 = wr("dram.txt", dram)
    n2 = wr("gold.txt", gold_w)
    n3 = wr("gold_addr.txt", gold_a, w=4)
    def jsonable(v):
        if isinstance(v, np.ndarray):  return v.tolist()
        if isinstance(v, np.generic):  return v.item()
        return v
    json.dump({k: {kk: jsonable(vv) for kk, vv in v.items() if kk != 'Wint'}
               for k, v in q.items()},
              open(os.path.join(args.out, "quant.json"), "w"), indent=1)
    print("-" * 74)
    print(f"  dram.txt {n1} / gold.txt {n2} / gold_addr.txt {n3}  -> {args.out}")

    if args.vivado:
        # xsim runs with its working directory here, so this is where
        # $readmemh("dram.txt") resolves. mem_init_files still holds the Task-1
        # MLP versions (50176-line dram.txt, 112-line gold.txt); leaving them
        # would silently feed the MLP's data to the CNN testbench.
        import shutil, glob
        targets = [
            os.path.join(args.vivado, "Task_1_26_summer.sim", "sim_1", "behav", "xsim"),
            os.path.join(args.vivado, "Task_1_26_summer.ip_user_files", "mem_init_files"),
        ]
        for t in targets:
            os.makedirs(t, exist_ok=True)
            for fn in ("dram.txt", "gold.txt", "gold_addr.txt"):
                shutil.copy2(os.path.join(args.out, fn), os.path.join(t, fn))
            print(f"  copied -> {t}")
        # the Task-1 per-layer goldens would only confuse a later debug session
        stale = glob.glob(os.path.join(targets[1], "gold_L*.txt"))
        if stale:
            print(f"  note: {len(stale)} stale Task-1 gold_L*.txt left in place "
                  f"(unused by tb_top)")
    print("=" * 74)


if __name__ == "__main__":
    main()
