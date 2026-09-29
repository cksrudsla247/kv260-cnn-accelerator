# Task 2 — CNN accelerator on Zedboard (XC7Z020)

Task 1 (MLP accelerator)
is complete and verified; this is the CNN follow-on that reuses its datapath.

---

## 1. Ground rules

- Verilog only, **not** SystemVerilog. Vivado 2019.2.
- Comments in RTL files are **English only**.
- Correctness and understanding come before resource efficiency.
- Every RTL change is verified bit-exact against a Python golden model. A
  mismatch is almost always a Python layout bug or an RTL timing bug, never
  quantisation noise.
- Every module gets a standalone testbench, and every testbench gets
  **mutation-tested**: break the DUT deliberately and confirm the test fails.
  A test that has never failed has not been shown to test anything. This has
  already caught three real bugs (see section 12).

---

## 2. Hardware, as built and synthesised

The PE array was **1024 PE (32x32) and did not fit**: 95,461 LUT = 179.44% of the
53,200 available. Measured cost is ~62 LUT per 8x8 multiplier plus ~20 LUT per
adder-tree node; DSP inference does not help because only ~124 DSP slices are
free and there are 1024 multipliers.

Utilisation on XC7Z020 (from the Vivado reports that are still on disk):

| array | PE   | LUT   | stage | verdict |
|-------|------|-------|-------|---------|
| 32x32 | 1024 | 95,461 = 179.44% | synthesis | no |
| **8x32** | **256** | **37,622 = 70.72%** | **post-route** | **confirmed** |

The 8x32 XC7Z020 run did **not** meet 100 MHz (WNS -0.936 ns). Timing closure
was reached on the KV260 (xck26): WNS +1.652 ns, LUT 37,294 = 31.84%.

### Confirmed parameters

```
ROW_SIZE     = 8      PE rows    : reduction width
COL_SIZE     = 32     PE columns : output channels in parallel
DATA_WIDTH   = 8      INT8 activations and weights
MEMORY_WIDTH = 32     DRAM / buffer word
NB_IN        = 2      ibuf banks   (ROW_SIZE*DATA_WIDTH/32)
NB_W         = 8      wbuf banks   (COL_SIZE*DATA_WIDTH/32)
NB_OUT       = 8      obuf banks
ROW_BIT      = 3      clog2(ROW_SIZE)
PE_OUT_WIDTH = 19     ROW_BIT + 16          <- clog2(ROW_SIZE), NOT COL_SIZE
ACCUM_WIDTH  = 24     PE_OUT_WIDTH + 5
BN_WIDTH     = 28     ACCUM_WIDTH + A_W(4)
TILE_WORDS   = 64     ROW_SIZE * NB_W
IB_A_BIT     = 5      ibuf depth 32   : holds W input columns (28 used)
WB_A_BIT     = 5      wbuf depth 32   : one tile is ROW_SIZE rows (8 used)
OB_A_BIT     = 6      obuf depth 64   : one drain chunk (64 used)
ACC_A_BIT    = 10     accumulator 1024 slots (784 used)
LEN_W        = 13     burst length / word index. 6272 > 1023.
LB_A_BIT     = 4      maxpool line buffer : OW/2, 14 used
```

**ROW_SIZE and DATA_WIDTH are both 8 and mean completely different things.**
ROW_SIZE is a count of values; DATA_WIDTH is the width of one value. One ibuf
row is `ROW_SIZE * DATA_WIDTH = 64` bits = 8 bytes = eight INT8 numbers, one per
PE row. This coincidence is the single most confusing thing in the parameter
list; every width expression states which one it means.

### Measured cost, 8 configurations through tb_controller

| layer | cycles | output pixels | DMA port busy |
|-------|--------|---------------|---------------|
| Conv1_1 | 11,368 | 784   (28x28)        | 87% |
| Conv1_2 | 65,527 | 196   (14x14, pool)  | 90% |
| Conv2_1 | 41,295 | 392   (14x14 x2 ft)  | 84% |
| Conv2_2 | 75,921 | 98    (7x7 x2 ft, pool) | 84% |
| Conv3   | 49,173 | 16    (2x2 x4 ft, pool) | 79% |
| Affine  | 5,497  | 1                    | 84% |
| **total** | **248,781** | | | 

**2.49 ms @ 100 MHz.** The old 223,000 estimate did not count the drain, the
s2mm traffic, or the per-tile fixed overhead. Every layer is DMA-bound, not
compute-bound — see section 13.

---

## 3. The one idea the whole design rests on

The PE array is a **vector-matrix multiply engine**: it takes ROW_SIZE bytes,
multiplies by a ROW_SIZE x COL_SIZE weight tile, and emits COL_SIZE results.
It does not know what those bytes mean.

Only axes that are **summed** in the layer equation may sit on PE rows, because
the adder tree unconditionally sums all ROW_SIZE products.

```
out[fn][oh][ow] = SUM_c SUM_fh SUM_fw  W[fn][c][fh][fw] * in[c][oh+fh-pad][ow+fw-pad]
                  ^^^^^^^^^^^^^^^^^^^  only these may go on PE rows
```

- input channel `c`, filter tap `(fh,fw)` -> summed -> PE rows or tiles
- output channel `fn` -> independent -> PE columns
- output pixel `(oh,ow)` -> independent -> time axis

`c` goes on the rows, ROW_SIZE at a time. `(fh,fw)` will not fit on the rows as
well, so it becomes separate passes that accumulate — which is what the
read-modify-write accumulator exists for.

Rule of thumb: if `C >= ROW_SIZE`, put channels on the rows and make `(fh,fw)`
into tiles. If `C < ROW_SIZE`, im2col the window onto the rows instead.

The pixel loop is **innermost**. That is what makes weight-stationary actually
pay off in CNN (784 reuses) where it did nothing in MLP at B=1 (1 reuse).

### Naming

The RTL uses the textbook names so it reads like the equation. The MLP-era
names are gone:

| textbook | RTL counter | was | meaning |
|----------|-------------|-----|---------|
| FN / COL_SIZE | `ft_cnt` | `og_cnt` | output-channel tile |
| C / ROW_SIZE  | `ct_cnt` | part of `ig_cnt` | input-channel tile |
| FH, FW        | `fh_cnt`, `fw_cnt` | `r`, `s` | filter tap |
| OH, OW        | `oh_cnt`, `ow_cnt` | — | output pixel |
| —             | `slot`   | — | accumulator address = output pixel |

`ig_max` no longer exists. The three reduction counters each wrap against their
own bound, so the flat product is never needed:

```verilog
acc_first = (ct_cnt==0) && (fh_cnt==0) && (fw_cnt==0);
tile_last = (ct_cnt==ct_max) && (fh_cnt==fh_max) && (fw_cnt==fw_max);
```

### There is no layer "mode" field

im2col, HWC and fc are the same loop with different CSR values, so the RTL has
no mode enum and no per-mode branches:

| layer | ct_max | fh_max, fw_max | pad | what it degenerates to |
|-------|--------|----------------|-----|------------------------|
| Conv1_1 | 1 (C_eff=16) | 0, 0 | 0 | 1x1 conv; `oob` can never fire |
| Conv1_2..Conv3 | 3 or 7 | 2, 2 | 1 | real 3x3 with padding |
| Affine | 143 | 0, 0 | 0 | H=W=OH=OW=1; address collapses to `ct` |

---

## 4. Network (Python, trained, 99.13% on MNIST)

VGG-style, every conv 3x3 stride 1, pool only at stage ends. Taken from
`convnet_hw.py CFG`, which is the authority — **Conv3 uses pad 0, not 1**:

```
Conv1_1   1 ->  32   3x3 pad1   28x28 -> 28x28   BN ReLU
Conv1_2  32 ->  32   3x3 pad1   28x28 -> 28x28   BN ReLU  Pool2 -> 14x14
Conv2_1  32 ->  64   3x3 pad1   14x14 -> 14x14   BN ReLU
Conv2_2  64 ->  64   3x3 pad1   14x14 -> 14x14   BN ReLU  Pool2 ->  7x7
Conv3    64 -> 128   3x3 pad0    7x7  ->  5x5    BN ReLU  Pool2 ->  2x2
Affine   512 -> 10                             (128 * 2 * 2)
```

An earlier version of this file said Conv3 was pad 1 giving 7x7 -> 3x3 and an
Affine of 1152 -> 10. That was wrong and it matters: it changes `pad`, `oh_max`,
`ow_max` and `ct_max` in the CSR program, and the weight table by 80 tiles.
Pooling a 5x5 map gives `int((5-2)/2 + 1) = 2`, so the last row and column are
discarded — which is why odd-dimension pooling is in the regression set.

Files: `convnet_hw.py` (net), `run_hw.py` (train + inference, saves
`params_hw.pkl`), `layers.py` (im2col Convolution/Pooling, BatchNorm_CNN with
running stats), `analyze_hw.py` / `explore_array.py` (cost models).

**BatchNorm_CNN must use running_mean / running_var at inference.** The
accelerator runs B=1; without running stats a single image would be normalised
by its own mean and could never match. `run_hw.py` checks batch=1 against
batch=200 accuracy for exactly this reason.

Bias is **not** implemented in RTL. Conv bias folds into the BN offset as
`a*bias + beta - a*mu`; the final Affine bias is dropped since argmax is
unaffected. Same trick as `quant_final.py` in Task 1.

---

## 5. Per-layer mapping

| layer | C | H,W | FN | FH,FW | pad | OH,OW | ct tiles | ft | tiles | pool |
|-------|---|-----|----|-------|-----|-------|----------|----|----|------|
| Conv1_1 | 1 -> **16*** | 28,28 | 32 | **1,1*** | **0*** | 28,28 | 2 | 1 | 2 | no |
| Conv1_2 | 32 | 28,28 | 32 | 3,3 | 1 | 28,28 | 4 | 1 | 36 | yes |
| Conv2_1 | 32 | 14,14 | 64 | 3,3 | 1 | 14,14 | 4 | 2 | 72 | no |
| Conv2_2 | 64 | 14,14 | 64 | 3,3 | 1 | 14,14 | 8 | 2 | 144 | yes |
| Conv3   | 64 | 7,7   | 128| 3,3 | **0** | **5,5** | 8 | 4 | 288 | yes |
| Affine  | **512** | 1,1 | 10 -> 32 | 1,1 | 0 | 1,1 | **64** | 1 | **64** | no |

`tiles = (C/ROW_SIZE) * FH * FW * (FN/COL_SIZE)`, **606** in total, **38,784**
DRAM words of weights.

### Conv1_1 — im2col, done in Python

C=1 so only 9 values are summed; they cannot form a contiguous 8-byte row in the
original image (rows are 28 apart). Python pre-expands each output pixel's 3x3
window into a flat row and zero-pads to 2 x ROW_SIZE, and also fills the conv
padding with zeros. **The RTL therefore needs no padding logic and no (fh,fw)
counter for this layer** — it is an ordinary layer with `ct_max = 1`.

Per output pixel: 16 bytes = 4 DRAM words.

```
group ct=0 : window taps 0..7          (1568 words = 784 pixels x 2)
  IN_BASE +        2p + 0 :  [w3][w2][w1][w0]
  IN_BASE +        2p + 1 :  [w7][w6][w5][w4]
group ct=1 : tap 8, then 7 zeros      (the other 1568 words)
  IN_BASE + 1568 + 2p + 0 :  [ 0][ 0][ 0][w8]
  IN_BASE + 1568 + 2p + 1 :  [ 0][ 0][ 0][ 0]

1568 = ct_stride = H*W*NB_IN. The two groups are NOT interleaved per pixel:
the address generator reads group ct from `ct_base = in_base + ct*ct_stride`,
so each group must be contiguous, exactly like every other activation.
```

`in_words = 784 * 4 = 3136`, **not 1568**. The old figure counted one tile per
pixel and contradicted the 9/16 utilisation figure in the same paragraph. The
`ct=1` tile's rows 1..7 must be written as **zero weights** by Python, because
the adder tree adds all ROW_SIZE products whether they are meaningful or not.

Cost: input DRAM balloons from 196 to 3136 words. PE utilisation is 9/16 = 56%.
Both are known and accepted; see section 13.

---

## 6. Dataflow — row streaming

> **`ARCHITECTURE.md`** is the module map and signal dictionary: what every
> module and signal is, the FSM state table, and the lead/lag rules in one
> place. **`DATAFLOW.md` is the long version of this section**: cycle-by-cycle traces of
> Conv1_1 and Conv1_2, the exact DRAM and buffer byte layouts, a signal-timing
> table, and why each decision went the way it did. Read it before touching
> `controller.v`.

This is the biggest departure from Task 1 and the reason the buffers did not
have to grow.

### The problem

With the pixel loop innermost, the naive reading is that the whole input feature
map must be resident. That would need

```
ibuf depth = H * W * (C/ROW_SIZE)      Conv1_2 : 28*28*4 = 3136 rows
```

against a buffer that is 32 deep. Nearly 100x. Section 11 of the old plan said
to grow ibuf to 1024 rows, which was **both too small and unnecessary**.

### The observation

Hold `(ct, fh, fw)` fixed and sweep the output pixels. Output pixel `(oh,ow)`
reads input `(oh+fh-pad, ow+fw-pad)`. Because `fh` is fixed for the whole sweep,
the input **row** is fixed too, and only the column moves:

```
input row    = oh + fh - pad      one row, fixed for the inner sweep
input column = ow + fw - pad      walks 0..W-1
```

The `fh` loop has already separated the vertical spread of the 3x3 window. So
only **one input row of one channel group** is ever live:

```
ibuf depth = W        28 for the widest layer, against a depth of 32
```

Measured usage across all six layers: ibuf 28/32, wbuf 8/32, obuf 64/64,
accumulator 784/1024. **No buffer IP had to change.**

### Why it is nearly free

The cost is that each input row is re-read `FH*FW = 9` times. That lands almost
for nothing because of an exact match:

```
one ibuf row  = NB_IN = 2 DRAM words        (load rate  2 words / pixel)
one pixel     = 2 cycles (accumulator RMW)  (compute rate 2 cycles / pixel)
```

So loading row `oh+1` hides completely underneath the pixel sweep of row `oh`.
**ibuf ping-pong is load-bearing, not an optimisation** — without it the load
and the sweep serialise and every layer doubles.

### Loop nest

```
for ft:                              output-channel tile
  for ct:                            input-channel tile
    for fh:
      for fw:
        load W tile (ft,ct,fh,fw)    64 words
        PUSH -> PE                   ROW_SIZE+1 cycles
        for oh:                      output row
          load input row (oh+fh-pad) of group ct    W*NB_IN words, prefetched
          for ow:                    output column
            ST_PIX_RD  ibuf address out, accumulator READ
            ST_PIX_WR  ibuf data in,     accumulator WRITE
  drain the COL_SIZE channels of every pixel, one obuf chunk at a time
```

### Pixel timing is 2 cycles, always

`acc_first` does **not** get a one-cycle fast path. The ibuf read latency is 1,
so in the cycle the address goes out the PE result does not exist yet:

```
ST_PIX_RD   ibuf_raddr = ow+fw-pad          accumulator read (if not first tile)
ST_PIX_WR   ibuf data valid -> pe_result    accumulator write
```

Nothing is lost: the input DMA needs 2 words per pixel anyway, so 2 cycles per
pixel is already the floor.

### Padding is two separate things

- **row out of range** (`oh+fh-pad` outside `[0,H)`): the whole row is padding.
  The load is *skipped* — no DRAM traffic — and the mask forces zeros.
- **column out of range** (`ow+fw-pad` outside `[0,W)`): individual pixels at
  the row ends. `ibuf_oob` masks the lanes.

Both use one unsigned compare, because `-1` wraps to a large value:

```verilog
wire [9:0] in_h = oh_cnt + fh_cnt - pad;
wire row_oob    = (in_h > h_max);        // catches -1 and >= H at once
```

`ibuf_oob` is **registered** so it arrives with the buffer data, not with the
address. Same lead/lag rule as everything else.

Verified: Conv1_2 at 4x4 loads 60 rows, not 72. `fh=0` skips the top row,
`fh=2` skips the bottom, `fh=1` loads all four: `3*(3+4+3)*2ct = 60`.

---

## 7. DRAM layout and the CSR map

### Activation layout — `(C/ROW_SIZE, H, W, ROW_SIZE)`

**Channel-group major, not pixel major.** Group `ct` of row `h` is then
contiguous:

```
word(ct, h, w) = base + ct*ct_stride + (h*W + w)*NB_IN
```

so one input row is a single linear burst, which is all `dma.v` can do. A
pixel-major (pure HWC) layout would scatter a row with stride `C/ROW_SIZE` and
could not be fetched at all with a linear-burst DMA.

The drain writes the same layout back: **one s2mm burst per output channel
group**, selected by `wb_grp`. A `ft` tile produces `COL_SIZE/ROW_SIZE = 4`
groups, so a drain chunk emits 4 bursts:

```
s2mm_base = out_base + (ft*4 + g)*og_stride + chunk_first*NB_IN
```

No multiplier: `ft_base` and `grp_base` are accumulators that add `og_stride`.

### CSR map — 10 registers, addresses 0..9

`csr_addr` was **already 4 bits** everywhere; only the convention said 0..7.
`tester.v` passes 0..13 straight through and reserves `4'hE` (end of program)
and `4'hF` (pulse start, wait for done) as program opcodes. **`tester.v` did
not have to change at all.**

```
addr  name        fields
------------------------------------------------------------------------
 0    CFG         [ 7: 0] ct_max    C/ROW_SIZE - 1        0..255
                  [ 9: 8] fh_max    FH - 1
                  [11:10] fw_max    FW - 1
                  [15:12] ft_max    FN/COL_SIZE - 1
                  [16]    pool_en
                  [17]    bn_en
                  [18]    relu_en
                  [19]    wide_out                        32-bit logits
                  [21:20] pad
 1    GEOM        [ 7: 0] h_max     H  - 1                input geometry
                  [15: 8] w_max     W  - 1
                  [23:16] oh_max    OH - 1                output geometry
                  [31:24] ow_max    OW - 1
 2    IN_BASE     [15:0]
 3    IN_WORDS    [12:0]   = H*W*C/4
 4    W_BASE      [15:0]
 5    OUT_BASE    [15:0]
 6    OUT_WORDS   [12:0]   = OH'*OW'*FN/4   (OH',OW' are POST-pool)
 7    START       [0]      written by tester opcode 4'hF
 8    POST        [3:0] rq_shift  [7:4] rq_mult  [12:8] bn_group
                  [14:13] bn_shift   BN s1, 0..3   see section 12
 9    STRIDE      [15:0] ct_stride  [31:16] og_stride
10-13             spare
```

`og_stride` and `out_words` are the **pooled** sizes. Pooling therefore needs no
CSR field beyond `pool_en`; Python computes the rest.

Geometry fields are 8 bits (not the 5 that MNIST needs) because the spare bits
cost nothing and a silent truncation there would be the fourth bug of that kind
in this project.

### Numeric formats, measured not assumed

The hardware's fixed formats were checked against the trained network before
writing any emitter. Two results, and they went opposite ways:

```
ACCUM_WIDTH = 24     theoretical worst case 127*127*576 = 25 bits  -> looks broken
                     MEASURED max |acc| over 500 images = 18-19 bits -> fine
```

The theoretical bound is ~100x pessimistic: ReLU'd activations and real weights
never hit +-127 together. **No change needed.**

```
                     first 500 images   full 10,000
S1 = 2 compiled in   forced      : 79.8%            79.97%   integer accuracy
                     per-layer   : 98.6%            99.17%
                     float       : 98.4%            99.13%
```

**19 points, so S1 became a CSR field.** See section 12.

Per-layer values the quantiser produces:

| layer | s1 | s2 | M2 | A range at its own s1 |
|-------|----|----|----|----------------------|
| Conv1_1 | **0** | 12 | 6 | needs the full 4 bits |
| Conv1_2 | 2 | 11 | 5 | |
| Conv2_1 | **3** | 11 | 7 | |
| Conv2_2 | 2 | 11 | 5 | |
| Conv3   | **3** | 11 | 5 | |
| Affine  | — | — | — | no BN, 32-bit logits straight from the accumulator |

Every BN offset fits in `B_W = 20` (worst is Conv3 at 16 bits).

### DRAM budget

```
weight table         38,784 words   606 tiles x 64
activation ping-pong 12,544         2 x the largest map (Conv1_1 output)
Conv1_1 im2col input  3,136
BN constants            432
CSR program              64
---------------------------------
TOTAL                54,960 words
dram IP as built     50,176         <- TOO SMALL, must be regenerated
16-bit address limit 65,536         <- hard ceiling, 92% used
```

`mm2s_base` / `s2mm_base` / `dram_addr` are all `[15:0]`. 65,536 words is a wall,
not a round number. If the weight table grows the whole address path widens.

### DRAM map

Task 1's map does not survive: the CNN weight table alone spans 0x0000..0xAB80,
which swallows the old BN base (0x9000) and the old program base (0xC300). Both
constants have been moved; **Python must emit against this map.**

| region | base | words | end |
|--------|------|-------|-----|
| weights | `0x0000` | 38,784 | `0x9780`, slack to `0xAB80` |
| BN constants | `0xAB80` | 432 | `0xAD30` |
| Conv1_1 im2col input | `0xAD30` | 3,136 | `0xB970` |
| activation A | `0xB970` | 6,272 | `0xD1F0` |
| activation B | `0xD1F0` | 6,272 | `0xEA70` |
| output logits | `0xEA70` | 16 | `0xEA80` |
| CSR program | `0xEA80` | 64 | `0xEAC0` |

54,960 words of live data inside a 60,096-word footprint. `BN_DRAM_BASE` is a
`localparam` in `controller.v`, so the slack after the weight table is left in
place rather than re-editing RTL every time the network changes.

`BN_DRAM_BASE` is a `localparam` in `controller.v` and `PROG_BASE` is one in
`tester.v` — they are compiled in, not CSR fields, so moving the map means
editing RTL. Activations ping-pong between A and B: layer N reads A and writes
B, layer N+1 reads B and writes A, set per layer by `in_base` / `out_base`.

---

## 8. accumulator.v — done and verified

32 lanes x 24 bit x 1024 slots, one `blk_mem_acc` BRAM IP per lane (single port,
width 24, depth 1024, **output register OFF** so read latency is 1). All lanes
share address and write strobe; only data differs.

**The module has no FSM and no flip-flops.** A single-port BRAM cannot read and
write in one cycle, so a read-modify-write takes two, but the *controller* owns
that sequence via `acc_ph`. This keeps the whole loop visible in one state
machine.

```
acc_first = 1                       written in ST_PIX_WR
  acc_en=1, acc_ph=0, acc_first=1   -> slot written with pe

acc_first = 0                       2 cycles
  acc_en=1, acc_ph=0, acc_first=0   -> read the slot        (ST_PIX_RD)
  acc_en=1, acc_ph=1                -> write back old + pe  (ST_PIX_WR)
```

`acc_addr` and `i_pe_result` must hold across both cycles. That is free: the PE
array is combinational, so holding `ibuf_raddr` holds `pe_result` too.

The BRAM is WRITE_FIRST, which only changes `douta` in the cycle *after* a
write; nothing reads it there.

Drain: `dr_en` / `dr_addr` read a slot; `o_accum_result` is valid **one cycle
later**. Never assert `dr_en` and `acc_en` together — shared port.

`tb_accumulator.v` passes 384 comparisons: plain write, 9-tile accumulate,
interleaved slots, lane independence, back-to-back RMW, high address.

---

## 9. maxpool.v — done and verified

2x2 stride 2, sitting between requant and obuf on the drain path. The drain
already walks the output map in raster order, which is exactly what a 2x2 pool
wants, so pooling costs no extra pass and no DRAM round trip.

```
h = (ow odd) ? max(left, cur) : cur        horizontal pair
oh even : line_buf[ow>>1] <= h             stash, emit nothing
oh odd  : emit max(line_buf[ow>>1], h)     vertical pair
```

Three decisions worth keeping:

- **Pool after requant, on INT8.** requant is a per-channel multiply by a
  positive constant and a right shift, which is monotonic, so
  `max(requant(a),requant(b)) == requant(max(a,b))`. Bit-identical, and it
  compares 8 bits instead of 28.
- **The line buffer is distributed RAM, not BRAM.** 16 x 256 bits total. An
  asynchronous read means the module adds **zero latency**, so the drain keeps
  its single lead/lag rule. A BRAM would add a second one to the part of the
  design that has caused the most bugs, to save a few hundred LUTs.
- **The compare is signed.** With `relu_en` on the values are non-negative and
  unsigned would agree, but `relu_en` is a per-layer CSR bit and nothing here
  should depend on it. Mutation-tested: unsigned fails immediately.

`tb_maxpool.v` passes 10,688 comparisons over 4x4, 8x8, 14x28, 28x28 and bypass.

---

## 10. Status — what is built and verified

| file | state | verification |
|------|-------|--------------|
| `accumulator.v` | rewritten, no FSM | 384 comparisons, 2 mutants caught |
| `dma.v` | widened to LEN_W=13 | 6 burst lengths, 10-bit version fails |
| `controller.v` | rewritten for row streaming | 11 layer shapes, 4 mutants caught |
| `maxpool.v` | new | 10,688 comparisons, 4 mutants caught |
| `core.v` | rewired | whole core elaborates with zero warnings |
| `pe_array_hier.v` | width bug fixed | see section 12 |
| `tester.v` | **unchanged** | csr_addr was already 4 bits |
| `batch_norm.v` | S1 is an input now | see section 12 |
| `python/quant_cnn.py` | new | emits dram/gold/gold_addr |

### The whole network is bit-exact

```
>>> PASS : bit-exact (928 words)     tb_top, 494,322 cycles, 6 layers
```

| layer | cycles | cumulative |
|-------|--------|-----------|
| Conv1_1 | 34,060 | 34,060 |
| Conv1_2 | 129,822 | 163,882 |
| Conv2_1 | 84,386 | 248,268 |
| Conv2_2 | 145,106 | 393,374 |
| Conv3 | 90,322 | 483,696 |
| Affine | 10,430 | 494,126 |

**4.94 ms @ 100 MHz**, measured through `tb_top` with real data (Icarus and
Vivado XSim agree to the cycle). The `tb_controller` model in section 2 predicts
2.49 ms because it assumes one DRAM word per cycle; the current `dma.v` is a
variable-latency handshake (written for the AXI4 path) and spends 2-3 cycles per
word even on a 1-cycle BRAM.

The golden set checks only what is still live when the program ends, because the
activation ping-pong overwrites each layer's output two layers later: Conv3's
map at ACT_A, Conv2_2's at ACT_B, the 16 logits at OUT_BASE. Every earlier layer
had its own bit-exact pass during bring-up, reproducible with
`quant_cnn.py --upto <layer>`.

### Conv1_1 and Conv1_2 are bit-exact

```
>>> PASS : bit-exact (7840 words)     tb_top, 11,512 + 67,559 cycles
```

Both layers are checked in one run: Conv1_1's output still sits in ACT_A when
Conv1_2 has finished writing ACT_B, so the ping-pong leaves the earlier layer
free to re-verify. From Conv2_1 on each layer overwrites the one before last, so
`quant_cnn.py` emits golden data only for the regions still live at the end.

Over Conv1_1, Conv1_2 adds: read-modify-write across 36 tiles, the (fh,fw) loop,
**zero padding**, maxpool in the datapath, the A->B activation ping-pong, and a
non-zero `bn_group`. It exposed two bugs, one RTL and one Python; both are in
section 12.

Every one of Conv1_1's 6,272 output words matches the Python integer model.
That single result validates the whole chain at once: weight tile order
`(ft,ct,fh,fw)`, the im2col group-major layout, `bank_unpack` byte order, the
8x32 PE array including the `OUTPUT_WIDTH` fix, the accumulator read-modify-
write, BN with a per-layer `s1`, ReLU, requant, the maxpool bypass, the obuf
group mapping, the channel-group s2mm layout, the CSR word encoding, and
`tester.v`'s program sequencer.

`tb_controller.v` covers Conv1_1 / Conv1_2 / Conv2_1 / Conv2_2 / Conv3 / Affine
shapes plus drain-chunk boundaries (64, 100, 128 pixels) and **odd-dimension
pooling** (7x7 and 9x9), and checks:

1. the layer terminates and pulses `done`
2. `acc_en` and `dr_en` are never high together
3. every accumulate is `ph=0` then `ph=1` on the same `acc_addr`
4. `acc_first` is high for the first weight tile only
5. each slot is visited once per tile, in raster order
6. `obuf_we` is exactly one cycle behind `dr_en && emit`
7. mm2s burst lengths match their kind; row loads skip padding rows
8. one s2mm burst per output channel group, at the right base and length
9. no buffer address exceeds the depth of the IP that backs it

---

## 11. What still has to be built

1. **`dram` IP 50,176 -> 65,536** in Vivado. Nothing else needs regenerating.
   The four buffer IPs stay exactly as built — measured usage is ibuf 28/32,
   wbuf 8/32, obuf 64/64, accumulator 784/1024.
2. **`tb_top.v`** — wire widths (`[9:0]` -> `[12:0]`) and the FSM debug hooks,
   which reference `ST_CDONE` / `ST_IN_WAIT` by name; those states no longer
   exist.
3. **`quant_cnn.py` layers beyond Conv1_1.** The quantiser already computes
   every layer's `(Wint, Aq, Bq, s1, s2, M2)` and the weight table for all 606
   tiles is already in `dram.txt`; only the CSR program is Conv1_1-only. Adding
   a layer is: append its `layer_csr(...)` with the right activation
   ping-pong (`ACT_A` -> `ACT_B` -> `ACT_A` ...), its `bn_group` offset, and its
   golden dump. Follow the bring-up order below rather than enabling all six.

### The BN path needs no work

Counted, because it was on this list by mistake. `bn_regfile.v` holds
`NUM_CH = 384` channels as 12 groups of 32, `A_W = 4` packed 8 per word and
`B_W = 20` one per word, 48 + 384 = 432 words. The CNN needs

```
Conv1_1 1 grp | Conv1_2 1 | Conv2_1 2 | Conv2_2 2 | Conv3 4 | Affine 1  = 11 groups
```

352 channels, `max(bn_group + ft) = 10`. The 4-bit slice in
`bn_group_base = {bn_group_sel[3:0], 5'b0}` holds 0..15, so it never reaches the
truncation it was flagged for. `bn_group` is 5 bits in the CSR purely as
headroom. Python must still emit the **full 432-word table** with the unused
groups zeroed, because the b-words are addressed as `waddr - 48`.

### Bring-up order

`Conv1_1 alone` (pixel loop, accumulator writes, drain delay) **done** ->
`Conv1_2` (RMW accumulate, (fh,fw) loop, padding, pooling) **done** ->
`Conv2_1` (ft loop > 1) -> rest by CSR values only.

`quant_cnn.py --upto <layer>` walks the layer list and derives every geometry
field, so adding a layer is one flag. The debug aids that found the Conv1_2
bugs are worth keeping:

- `--debug-nopool` forces `pool_en=0` on the last layer and checks the un-pooled
  map. Separates a reduction bug from a maxpool bug, and the result is
  invertible back to accumulator values where a pooled map is not.
- `mkdebug.py` preloads a known-good activation into ACT_A and runs ONE
  synthetic layer over it: `--taps center|nopad|full`, `--ct N`. Conv1_1 out of
  the picture, one feature at a time.
- `probe.py` / `probe4.py` make the weights an IDENTITY - one output channel
  picks one (group, tap) with weight 1 - and BN a no-op (A=1, B=0, s1=s2=0,
  M2=1), so **the output byte IS the input byte the hardware fetched**. The
  input values encode their own coordinates, so a wrong address reads back as a
  number naming the row, column and channel group actually read. This turned
  "65% of bytes are wrong" into "fh=0 taps read 16 rows too far" in one run.
- `analyze_got.py` reports WHERE the errors are - per row, per column, per
  channel, plus spatial-shift and channel-permutation tests. `tb_top` dumps
  every compared word to `got.txt` for it. 24 `$display` lines never show
  structure; the full map does.

---

## 12. Traps that have already bitten this project

- **BRAM read latency 1 is the dominant bug source.** Address must lead, the
  consumer must lag. Every interface: `push_cnt_d1` for the PE row,
  `ST_PIX_RD`/`ST_PIX_WR` for ibuf, `ibuf_oob` registered to match, and
  `dr_en` -> `obuf_we` for the accumulator. Mutating the last one back to the
  MLP's same-cycle write fails `tb_controller` on the first drained pixel.
- **`pe_array_hier.v` used `$clog2(COL_SIZE)` where it meant `$clog2(ROW_SIZE)`.**
  The adder tree sums ROW_SIZE products, so the growth is 3 bits, not 5.
  `OUTPUT_WIDTH` came out 21 instead of 19, so `o_result` was 672 bits against
  `core.v`'s 608-bit `pe_result`: every lane misaligned and the top two bits of
  each undriven. **Harmless at 32x32 where ROW_SIZE == COL_SIZE, fatal at 8x32.**
  This is the second bug of exactly this shape in this exact file — the first
  was `i_weight` declared `ROW_SIZE` wide but indexed by column. When a width
  expression names a dimension, check it against what the hardware actually
  sums.
- **Odd output dimensions break "last index + 1" counting.** Conv3 pools 7x7 to
  3x3, so the last drained pixel (6,6) is one that does **not** emit, and the
  emitted-pixel counter has already moved past the last emission. `out_row`
  became a count rather than a last index, with one spare bit so it can reach
  `OB_DEPTH`. Every even shape passed before this was found — 4x4, 8x8, 14x14
  and 28x28 all hide it.
- **A ping-pong that swapped once per BURST instead of once per CHUNK.**
  `ST_OUT_REQ` is entered `COL_SIZE/ROW_SIZE = 4` times per drain chunk, one
  burst per output channel group. Swapping obuf on each of them handed the read
  side to the empty half right after group 0, so groups 1..3 streamed zeros.
  The symptom was exact and diagnostic: the first `og_stride` words correct and
  the rest of the map blank. **`tb_controller` passes all six layer shapes with
  and without this bug** - it checks the control sequence, and buffer-select is
  a datapath effect. Only `tb_top` with real golden data found it. Control-level
  testing has a ceiling, and this was it.
- **A compile-time numeric constant that happened to fit one network.**
  `batch_norm.v` had `parameter S1 = 2` because every MLP layer landed there,
  and `quant_final2.py` even asserts it. The CNN's five conv layers want
  `0, 2, 3, 2, 3`: Conv1_1's `a` saturates the 4-bit field at s1=2 and integer
  accuracy drops from 98.6% to **79.8%** (500 images; 99.17% to 79.97% on all 10,000). `S1` is now `i_s1`, an input driven
  from CSR8[14:13]. The lesson is not about this one constant — it is that a
  quantisation format validated against one network is not validated, and the
  check costs one script.
- **A datapath selector consumed at the WRITE must be registered like the
  write.** `wide_half_sel` picks which 16 accumulator lanes `core.v` packs into
  32-bit logits, and that packing happens at the obuf write - one cycle behind
  the drain read that toggles the bit. `obuf_we` and `obuf_waddr` were already
  registered for exactly this reason; this one bit was not, so the Affine emitted
  the upper half first and the lower half second. **Every value was correct and
  the order was wrong**, which is a signature worth recognising: it points at
  lead/lag, never at arithmetic. Fixed with `wide_half_sel_d1`, registered
  alongside `obuf_we`; control keeps using the live bit.

- **`$signed()` on an operand does not make the expression signed.**
  `row_base0 = ct_base + ($signed(fh_off) * $signed({1'b0, row_step}))` computed
  `fh - pad = -1` as **+15**. Verilog makes an entire expression unsigned as
  soon as any operand is unsigned - `ct_base` is a plain `reg [15:0]` - and a
  context-determined operand takes the signedness of the expression it sits in,
  not its own. So the multiply was an UNSIGNED multiply and every `fh=0` sweep
  started `15*row_step` forward instead of one row back. The `$signed()` calls
  were there as protection and provided none, which is what made this hard: the
  line looks like it has already been thought about. The fix forms both products
  unsigned and subtracts, so no signedness rule can apply:
  `fh_fwd = fh_cnt*row_step; pad_back = pad*row_step; ct_base + fh_fwd - pad_back`.
  **Invisible whenever `pad = 0`**, which is Conv1_1 and every isolation test
  that had been written up to that point. If a signed value must meet an
  unsigned one, give the signed part its own named wire first.

- **A CSR field that is printed but not asserted is not checked.**
  `layer_csr` emitted the constant `W_BASE` for CSR4 instead of `wptr[name]`,
  the layer's own weight pointer, which `main()` computed and never used.
  Conv1_1 sits at 0x0000 so it was right for exactly one layer and wrong for
  every later one: Conv1_2 read its 36 tiles starting two tiles early, inside
  Conv1_1's table. The value `CSR4 0x00000000` was in the readback dump from the
  very first run - the checker asserted CSR0 and merely *printed* the rest.
  The readback now parses the program into layers at each `0xF` and asserts
  CSR0 and CSR4 per layer. Anything worth printing to catch a bug is worth an
  assert; printing it only proves it was emitted, not that it was right.

- **Bisect with the CSR, not with the waveform.** Conv1_2 failed with 65% of
  bytes wrong, uniformly across rows, columns and channels, with no spatial
  shift and no channel permutation - a shape that rules out every *structural*
  hypothesis and leaves eighteen arithmetic ones, all of which were tested
  against the hardware dump and all of which scored at the noise floor. What
  worked was turning features off one at a time through CSR values alone:
  `1 tap, pad 0` PASS -> `3x3, pad 0` PASS -> `3x3, pad 1, identity weights`
  PASS -> real layer FAIL. Each step is one Python run and one `restart`, no
  RTL edit. The last gap between a passing isolation test and the failing real
  layer is the bug, and here there were two - which is also why the first fix
  changed the numbers without fixing the layer. **A partial improvement after a
  fix means keep bisecting, not that the fix was wrong.**

- **Silent truncation.** `mm2s_len` at 10 bits turns a 3,136-word request into
  64 (`3136 mod 1024`) and still pulses `done`. `ig_max` at 5 bits truncated the
  Affine layer's 144. Both were invisible. Any field that indexes DRAM or counts
  loop iterations gets checked against its worst case, and the CSR geometry
  fields are deliberately over-wide.
- **Signed vs unsigned in testbench comparisons.** A max-tracking `integer`
  initialised to `-1` and compared against an unsigned wire promotes to
  4294967295, so nothing ever exceeds it and every range check silently reports
  zero. The buffer-usage table read "0 / 32" for every buffer until this was
  found.
- **Combinational vs registered discipline.** Anything that must track the
  current state for immediate downstream use is combinational; anything
  compensating for pipeline latency is registered. Several past bugs were this
  backwards.
- **A DMA `req` line stays high through its own `done` cycle.** Any behavioural
  DMA model must mirror the `S_IDLE` guard in `dma.v` or it starts the same
  burst twice. This produced a phantom second BN load in `tb_controller`.
- **Vivado compiles stale sources.** If behaviour does not respond to a change,
  confirm a `$display` actually changed, and delete the `.sim` folder for a
  clean rebuild.
- **Ping-pong needs two separate BRAM IP instances.** One deeper instance cannot
  write one half while reading the other.
- `strm_waddr` had to split into `ibuf_waddr` / `wbuf_waddr` because ibuf has 2
  banks and wbuf has 8, so one DRAM word lands in different rows of each.

---

## 13. Known inefficiencies, deliberately accepted

**Every layer is DMA-bound.** The port is busy 76-90% of the run; the remaining
idle is state-transition bubbles, not compute. Compute is never the limit:
Conv1_2 spends 56,448 cycles on pixels against 58,752 words of DMA.

A **DMA request queue was investigated and rejected.** The initial reasoning —
that `ST_ROW_REQ` waits 64 cycles doing nothing — was wrong: during that wait
the DMA is streaming the weight tile, which is productive. Queueing DMA requests
behind other DMA requests gains nothing on a single-port memory that moves one
word per cycle. What did help was moving the weight prefetch onto the **last row
sweep** of the previous tile, which is the one stretch where there is no next
row to fetch and the port genuinely idles. That is worth 2.8% and costs nothing
in `dma.v`.

That change has a trap: a layer with `OH == 1` (Affine) has no row sweep to hide
behind, and moving the prefetch there made it **7% slower** by uncovering
`ST_PUSH`. The `single_row` condition splits the two placements. This is a
structural condition — "is there a sweep to hide behind" — not a tuned constant.

**Row streaming costs ~8% over a fully-resident feature map** and buys a 128x
smaller ibuf. It also scales: ibuf depth tracks `W`, not `H*W*C/ROW_SIZE`, so a
224x224 input would need depth 256 — about one BRAM36 — where the resident
version would need 401,408 rows. The accumulator (`OH*OW <= 1024`) becomes the
binding constraint first, and the fix there is the same trick one level up:
process a band of output rows, drain, next band.

**Conv1_1 low-channel problem.** C=1 wastes PE rows. This is a well documented
industry problem, not a design flaw: Xilinx dedicates a second systolic array to
the first layer; Kung's group at Harvard reshapes the input instead (2x2 pixel
blocks folded into channels), which also *improved* accuracy by ~4%; AWS has a
patent on mapping several filter taps onto several rows, which is what the
im2col path here does.

Conv1_1 spends ~96% of its cycles with the DMA busy (32,813 of 34,060 in `tb_top`), not computing. **Raising PE
utilisation there buys almost nothing** — splitting the adder tree three ways
would gain 4%, while space-to-depth (2x2 -> 4 channels) cuts the layer 73% by
shrinking the data. That is the improvement to write up, and to implement only
after the pipeline works.

**Small-P layers pay a fixed per-tile overhead.** Conv3 and Affine spend more
than half their cycles on tile setup because `OH*OW` is 49 and 1. The same
pattern shows up everywhere in this design: batch parallelism, array shape, and
prefetch placement all come down to whether `P` is large enough to amortise
something.

**Affine wants the opposite array shape.** Per-layer optimum analysis at equal PE
count: conv layers prefer wide columns, Affine prefers wide rows, by 3.8x. Fixing
one array costs ~10% overall. This is the quantitative case for why DNPU splits
CNN and FC/RNN into separate reconfigurable processors.

**The batch (N) loop was removed.** In the MLP it existed to keep the
accumulator at 32 registers; in the CNN the pixel loop took over that role, and
`N` and `(OH,OW)` are the same kind of axis (independent, on the time axis).
With `img` outermost the cost is exactly B x — identical to replaying the CSR
program — so the FSM loop bought nothing over a PS-level loop. Fusing `N` into
the pixel loop *would* pay, but needs `B*OH*OW` accumulator slots: 64 BRAM36
instead of 32 at B=2, plus B x ibuf, roughly 31% of the device to buy ~2%,
because `P = 784` has already amortised the weights to nothing everywhere except
Affine. Batch now lives at the CSR-program level: change `in_base`, replay.

---

## 14. Layout and files

Working dir: `<rtl_proj>/`. Model code under `<mnist-cnn-from-scratch>/04_CNN/`
(https://github.com/cksrudsla247/mnist-cnn-from-scratch).

Python: `python/quant_cnn.py`. Run it with
`--t2 "<mnist-cnn-from-scratch>" --upto Affine`; it writes `dram.txt`, `gold.txt`,
`gold_addr.txt` and `quant.json` next to itself, which is where `tb_top` looks
for them when the simulation runs from that directory.

RTL: `top.v`, `core.v`, `controller.v`, `dma.v`, `accumulator.v`, `maxpool.v`,
`bn_regfile.v`, `batch_norm.v`, `ReLU.v`, `requant.v`, `input_buffer.v`,
`weight_buffer.v`, `output_buffer.v`, `bank_unpack.v`, `pe_array_hier.v`,
`pe_adder_tree.v`, `pe_col.v`, `PE.v`, `multiplier.v`, `adder_tree.v`,
`tester.v`, `tb_top.v`.

Testbenches: `tb_accumulator.v`, `tb_controller.v`, `tb_maxpool.v`, `tb_top.v`.

`tester.v` models the PS: owns the DRAM (`blk_mem_gen` 32b x 50176) and replays
a CSR program stored in that same DRAM at `PROG_BASE`. Two words per entry
(addr, data); `4'hF` pulses start and waits for done, `4'hE` ends the program.
This is a design source, not a testbench, and carries over unchanged.

IP cores: `blk_mem_gen_0` (ibuf bank 32b x 32), `blk_mem_gen_1` (wbuf bank
32b x 32), `blk_mem_gen_2` (obuf bank 32b x 64), `blk_mem_acc` (24b x 1024),
`dram` (32b x 50176, **needs 65,536**). All single port, WRITE_FIRST, output
register off.

Task 1 DRAM map (to be reworked for CNN sizes): W 0x0000-0x6900, INPUT 0x7000,
BN 0x9000, ACT1-4 0xA000/0xA800/0xB000/0xB800, OUT 0xC000, PROG 0xC300.

---

## 15. Python — what the RTL now expects

The RTL side fixes the contract, so this is a specification, not a design task.

### The trained network already exists

```
<mnist-cnn-from-scratch>/params_hw.pkl
```

Note the location: one level ABOVE `04_CNN/`, because `run_hw.py` uses the
relative path `PKL = "params_hw.pkl"` and was run from the repository root. Verified by
inference on 2026-08-24:

```
full 10000            0.9913      <- matches section 4
first 200, batch=1    0.9950
first 200, batch=200  0.9950      <- equal, so BN running stats are live
Conv5 -> (1,128,5,5)  Pool5 -> (1,128,2,2)  Affine1 -> (1,10)
```

**`run_hw.py` is a TRAINING script, not an inference script.** It runs 8 epochs
and calls `net.save_params(PKL)`, overwriting the file. Running it replaces the
verified 99.13% network with a differently-initialised one and silently
invalidates every golden value. There is no reason to run it.

### Layer naming

`params_hw.pkl` indexes layers 1..6; this document names them by stage. The
quantiser has to map between them:

| pkl | `net.layers` | this document |
|-----|--------------|---------------|
| `W1`, `gamma1`, `running_mean1` | `Conv1` | Conv1_1 |
| `W2`, `gamma2`, ... | `Conv2` | Conv1_2 |
| `W3` | `Conv3` | Conv2_1 |
| `W4` | `Conv4` | Conv2_2 |
| `W5` | `Conv5` | Conv3 |
| `W6` (512, 10) | `Affine1` | Affine |

Conv weights are `(FN, C, FH, FW)`; the Affine weight is `(512, 10)`, so it
needs a transpose to become `(FN=10, C=512)` before tiling.

1. **Per-channel INT8 quantisation**, BN folded to `(A,B)` with conv bias
   absorbed as `a*bias + beta - a*mu`, requant as `M2 >> shift`. Follow
   `quant_final2.py` from Task 1, but **drop its `assert S1 == 2`** — the shift
   is per-layer now and goes in CSR8[14:13].
2. **Weight emit order `(ft, ct, fh, fw)`, `fw` fastest.** One tile is
   `ROW_SIZE x COL_SIZE` INT8 = 64 DRAM words; word `8r+b` byte `j` holds
   `W[fn = 4b+j][c = ct*ROW_SIZE + r][fh][fw]`. **A mismatch here is bit-exact
   failure with no visible cause** — the waveform looks correct.
3. **Activation layout `(C/ROW_SIZE, H, W, ROW_SIZE)`**, channel-group major.
   **The Affine layer needs a permutation.** Conv3's drain writes
   `byte = ct*(H*W*8) + (h*W+w)*8 + cl` with H=W=2, so channel `c = ct*8+cl`
   lands at `ct*32 + (h*2+w)*8 + cl`. `W6` is indexed by the numpy flatten
   order `c*4 + h*2 + w`. Those are different orderings, so the Affine weight
   rows must be permuted to the hardware's read order before tiling.
4. **Conv1_1 im2col**: 4 words per output pixel, conv padding pre-filled with
   zeros, and the `ct=1` tile's unused weight rows written as zeros.
5. **CSR program** per section 7, including `ct_stride = H*W*NB_IN` and
   `og_stride = OH'*OW'*NB_IN` on the **pooled** output size.
6. **Per-layer golden dumps** for the bit-exact check, in the same layout the
   RTL writes.
