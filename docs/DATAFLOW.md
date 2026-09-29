# CNN accelerator — dataflow, decisions, and a worked example

Companion to `DESIGN_NOTES.md`. That file is the design record; this one explains
**how a layer actually runs, cycle by cycle and address by address**, and why
each decision went the way it did.

Read this before touching `controller.v`.

---

## 0. The machine in one paragraph

The PE array is 8 rows x 32 columns. Every cycle it can take **8 INT8 numbers**
in and produce **32 partial sums** out, using 256 weights that were loaded into
it beforehand and then held. It has no idea what those numbers mean. The entire
rest of the design exists to answer two questions:

> **Which 8 numbers do we feed it next, and where does the answer go?**

---

## 1. Why the loops are nested the way they are

### 1.1 Only summed axes can go on PE rows

```
out[fn][oh][ow] = SUM_c SUM_fh SUM_fw  W[fn][c][fh][fw] * in[c][oh+fh-pad][ow+fw-pad]
```

The adder tree adds **all 8 products unconditionally**. There is no way to tell
it "only add 5 of these". So anything placed on a PE row must be an axis that
the layer equation is already summing over. That is `c`, `fh`, `fw` — and
nothing else.

- `c` (input channel) → **PE rows**, 8 at a time. Conv1_2 has C=32, so 4 tiles.
- `fh, fw` (filter taps) → 8 rows are already used by `c`, so these become
  **separate passes whose results are added up over time**. That is the entire
  reason the accumulator does read-modify-write.
- `fn` (output channel) → not summed, so it goes on the **32 columns**.
- `oh, ow` (output pixel) → not summed, so it goes on the **time axis**.

### 1.2 The pixel loop is innermost, and that is the whole point

A weight tile costs 64 DRAM words to fetch. Once it is inside the PE array it
is free to reuse. So the loop that runs innermost decides how much that fetch is
amortised:

| innermost loop | reuses per tile fetch | layer |
|----------------|-----------------------|-------|
| batch, B=1 (the MLP) | **1** | weight-stationary bought nothing |
| output pixel, 28x28 | **784** | Conv1_2 |

This is why the MLP's design could not simply be reused. In the MLP the batch
loop was outermost so that only one partial-sum set was alive and the
accumulator could be 32 registers. In the CNN, 784 partial-sum sets are alive at
once, so the accumulator becomes a 1024-slot BRAM — and that is a trade worth
making, because it turns 1 reuse into 784.

### 1.3 Final loop nest

```
for ft   in 0..FN/32-1:          which 32 output channels
  for ct in 0..C/8-1:            which 8 input channels
    for fh in 0..FH-1:
      for fw in 0..FW-1:
        fetch W tile (ft,ct,fh,fw)          64 words
        push it into the PE array           9 cycles
        for oh in 0..OH-1:
          fetch input row (oh+fh-pad) of group ct    W*2 words, prefetched
          for ow in 0..OW-1:
            acc[oh*OW+ow] += in_row[ow+fw-pad] . W   2 cycles
  drain all output pixels of this ft out to DRAM
```

**`fw` is the fastest-moving reduction index.** The Python weight emitter must
match `(ft, ct, fh, fw)` exactly. A mismatch here produces wrong numbers with a
completely normal-looking waveform.

---

## 2. Row streaming — the decision that saved the buffers

### 2.1 The trap

The obvious reading of "pixel loop innermost" is that the whole input feature
map has to be resident:

```
ibuf depth = H * W * (C/ROW_SIZE)
Conv1_2    = 28 * 28 * 4 = 3136 rows
```

The buffer is 32 deep. That is 98x short. The original plan said to grow it to
1024 rows, which was **both wrong and unnecessary** — 1024 is still 3x too small,
because the `* C/ROW_SIZE` term had been dropped.

### 2.2 The observation

Fix `(ct, fh, fw)` and sweep the pixels. Look at what is actually read:

```
input row    = oh + fh - pad
input column = ow + fw - pad
```

`fh` is **constant for the whole sweep**, so the input row is constant too. Only
the column moves. The `fh` loop has already pulled the 3x3 window apart
vertically — the hardware never needs to see more than one row at a time.

```
ibuf depth needed = W          28 for the widest layer.  Depth is 32.
```

Measured across all six real layers: **ibuf 28/32, wbuf 8/32, obuf 64/64,
accumulator 784/1024.** Not one buffer IP had to be regenerated.

### 2.3 Why it is nearly free — the 2-and-2 coincidence

Each input row is now re-read `FH*FW = 9` times. That sounds expensive. It is
almost free, because of an exact rate match:

```
one ibuf row  = NB_IN = 2 DRAM words     ->  load    2 words per pixel
one pixel     = 2 cycles (RMW)           ->  compute 2 cycles per pixel
```

Loading row `oh+1` takes exactly as long as sweeping row `oh`. With ibuf
ping-pong the load disappears completely underneath the compute.

> **ibuf ping-pong is load-bearing, not an optimisation.** Remove it and the
> load and the sweep serialise: every layer doubles.

Cost against a fully-resident map: about **8%**. Benefit: a **128x smaller
ibuf**, and it scales — depth tracks `W`, not `H*W*C/8`. A 224x224 input would
need depth 256, about one BRAM36, where the resident version would need 401,408
rows.

---

## 3. Memory layout

### 3.1 Activations — `(C/8, H, W, 8)`, channel-group major

This is **not** plain HWC. Group `ct` of row `h` is contiguous:

```
word(ct, h, w) = base + ct*ct_stride + (h*W + w)*2        ct_stride = H*W*2
```

**Why not pixel-major (plain HWC)?** Because `dma.v` only does linear bursts —
`address of word w = base + w`. In pixel-major layout, one channel group of one
row is scattered with stride `C/8`:

```
pixel-major : [p0: ct0 ct1 ct2 ct3][p1: ct0 ct1 ct2 ct3]...
              reading ct=1 of a row means every 4th entry.  Not a burst.

group-major : [ct0: all pixels][ct1: all pixels]...
              reading ct=1 of row h is 28 consecutive entries.  One burst.
```

The drain writes the same layout back, which means **one s2mm burst per output
channel group**. One `ft` tile produces 32 channels = 4 groups, so a drain chunk
fires 4 bursts:

```
s2mm_base = out_base + (ft*4 + g)*og_stride + chunk_first*2
```

No multiplier anywhere: `ft_base` and `grp_base` are accumulators that add
`og_stride`.

### 3.2 Buffer packing — where each byte lands

```
ibuf row (8 bytes = 8 PE rows) = 2 consecutive DRAM words, LSB byte first

  lane 0..3 = even word, bytes 0,1,2,3
  lane 4..7 = odd  word, bytes 0,1,2,3

wbuf row (32 bytes = 32 PE columns) = 8 consecutive DRAM words
  word 8r+b, byte j  ->  W[fn = 4b+j][reduction index r]
```

A weight tile is 8 wbuf rows = 64 words. Row `r` is "the weights connecting
input lane `r` to all 32 output channels".

### 3.3 DRAM budget

```
weight table         38,784 words   606 tiles x 64
activation ping-pong 12,544         2 x the largest feature map
Conv1_1 im2col input  3,136
BN constants            432
CSR program              64
---------------------------------
TOTAL                54,960
dram IP as built     50,176         <- must be regenerated
16-bit address limit 65,536         <- hard ceiling; 92% used
```

`mm2s_base`, `s2mm_base` and `dram_addr` are all `[15:0]`. 65,536 is a wall.

---

## 4. Worked example — Conv1_1, start to finish

`C=1, H=W=28, FN=32, FH=FW=3, pad=1`. C=1 means only 9 values are summed, and
they sit 28 bytes apart in the image, so they can never form a contiguous 8-byte
row. **Python pre-expands the window.** The hardware then sees an ordinary 1x1
convolution over a 16-channel input.

### 4.1 What Python writes

For output pixel `p = oh*28 + ow` (0..783), the 3x3 window row-major as
`w0..w8`, zeros where outside the image:

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

`in_words = 784 * 4 = 3136`, sixteen times the original 196-word image. PE
utilisation is 9/16 = 56%. Both are accepted — see `DESIGN_NOTES.md` section 13.

Weights, two tiles of 64 words:

```
W_BASE +  0..63  :  tile (ft=0, ct=0)   rows 0..7 -> window positions 0..7
W_BASE + 64..127 :  tile (ft=0, ct=1)   row  0    -> window position 8
                                        rows 1..7 -> MUST BE ZERO
```

Rows 1..7 of the second tile must be written as zeros because the adder tree
adds all 8 products whether they mean anything or not.

### 4.2 CSR program

```
CSR0 = ct_max 1 | fh_max 0 | fw_max 0 | ft_max 0 | pool 0 | bn 1 | relu 1 | pad 0
CSR1 = h_max 27 | w_max 27 | oh_max 27 | ow_max 27
CSR2 = IN_BASE      CSR3 = 3136
CSR4 = W_BASE       CSR5 = OUT_BASE     CSR6 = 6272
CSR8 = rq_shift, rq_mult, bn_group 0
CSR9 = ct_stride 1568 | og_stride 1568
CSR7 = start
```

`fh_max = fw_max = 0` and `pad = 0` mean `in_h = oh` and `in_w = ow` always, so
`oob` can never fire — no padding logic runs. That is the whole "no mode field"
idea: Conv1_1 is not a special case, it is a set of CSR values.

### 4.3 Cycle trace

```
ST_BN_REQ / WAIT     432 words of BN constants
ST_TILE_REQ / WAIT   tile (ct=0), 64 words                     blocking, once
ST_TSWAP             hand it to the PE
ST_PUSH              wbuf rows 0..7 -> PE registers            9 cycles
ST_ROW_REQ / WAIT    input row oh=0, group ct=0, 56 words      blocking, once
ST_RSWAP             swap ibuf; post the prefetch for oh=1
  ST_PIX_RD  ow=0    ibuf_raddr = 0                            address out
  ST_PIX_WR  ow=0    data valid -> pe_result; acc[0] = pe      acc_first
  ST_PIX_RD  ow=1    ...
  ...                                                          56 cycles total
ST_ROW_END           row 1 already landed (56 words / 56 cycles)
ST_RSWAP             oh=1 ... repeated for 28 rows
                     on the LAST row, post the next weight tile instead
ST_TILE_END          wait for that tile
ST_TSWAP -> ST_PUSH  tile (ct=1)
  ... 784 pixels again, this time acc_first = 0 (read-modify-write)
ST_DRAIN             64 pixels -> obuf
ST_DR_TAIL           one extra cycle: the last obuf write lags
ST_OUT_REQ x4        one s2mm burst per channel group, 128 words each
ST_CHUNK_END         next chunk ... 13 chunks for 784 pixels
ST_DONE
```

**Measured: 11,368 cycles, DMA port busy 87%.**

### 4.4 What one pixel actually does

Pixel `p=147` (`oh=5, ow=7`), tile `ct=0`:

```
ST_PIX_RD                                   ST_PIX_WR
  ibuf_raddr = ow + fw - pad = 7              ibuf lanes valid: [w0..w7]
  ibuf_oob   <= (row_oob || col_oob) = 0      PE: 8x32 multiply, adder tree
  acc_en = 0 (acc_first, nothing to read)     acc_en=1 ph=0 first=1 addr=147
                                              -> slot 147 written with pe
```

Then tile `ct=1` sweeps the same 784 pixels again, and pixel 147 does:

```
ST_PIX_RD                                   ST_PIX_WR
  ibuf_raddr = 7   (row 2p+1 is resident)     lanes = [w8,0,0,0,0,0,0,0]
  acc_en=1 ph=0 first=0 addr=147              acc_en=1 ph=1 addr=147
  -> BRAM read issued                         -> slot 147 = old + pe
```

That is the whole read-modify-write, and it is why `acc_addr` and
`i_pe_result` must hold across both cycles. Holding them is free: the PE array
is combinational, so holding `ibuf_raddr` holds `pe_result`.

---

## 5. Worked example — Conv1_2, where the real CNN starts

`C=32, H=W=28, FN=32, FH=FW=3, pad=1, pool`. No im2col. 36 tiles.

### 5.1 The read

Pixel `(oh,ow) = (5,7)`, tile `(ct=1, fh=2, fw=0)`:

```
in_h = 5 + 2 - 1 = 6            input row 6
in_w = 7 + 0 - 1 = 6            input column 6
read : in[channels 8..15][row 6][col 6]     8 bytes, one ibuf entry
acc  : slot 5*28 + 7 = 147
```

Because the ibuf holds only row 6 of group 1, `ibuf_raddr` is just `in_w = 6`.
The row and the channel group are baked into *which row was loaded*. The address
generator is one adder.

### 5.2 Padding, two different mechanisms

```
row out of range   oh+fh-pad outside [0,H)   -> the LOAD is skipped entirely
column out of range ow+fw-pad outside [0,W)  -> ibuf_oob masks the lanes
```

Both use one unsigned compare, because `-1` wraps to a large number:

```verilog
wire [9:0] in_h = oh_cnt + fh_cnt - pad;
wire row_oob    = (in_h > h_max);     // catches -1 AND >= H with one compare
```

Verified on a 4x4 version: 60 row loads, not 72.

```
fh=0 : in_h = oh-1  -> oh=0 gives -1, skipped        3 of 4 rows
fh=1 : in_h = oh    -> all valid                     4 of 4
fh=2 : in_h = oh+1  -> oh=3 gives 4 >= H, skipped    3 of 4
per ct : 3 fw values x (3+4+3) = 30    x 2 ct = 60
```

`ibuf_oob` is **registered**, so it arrives with the buffer data rather than
with the address. This is the same lead/lag rule as everywhere else, and getting
it wrong would mask the wrong pixel.

### 5.3 Accumulation over 36 tiles

Slot 147 receives 36 additions before it is complete:

```
tile  1 (ct=0,fh=0,fw=0)  acc_first=1  ->  slot 147 =  pe
tile  2 (ct=0,fh=0,fw=1)  acc_first=0  ->  slot 147 += pe
...
tile 36 (ct=3,fh=2,fw=2)  acc_first=0  ->  slot 147 += pe   complete
```

Only the first is a plain write. The other 35 are 2-cycle read-modify-writes.

**Measured: 65,527 cycles, DMA busy 90%.**

---

## 6. The drain, and why it is the most dangerous part

### 6.1 The pipeline

```
cycle k    : dr_en = 1, dr_addr = slot            accumulator read issued
cycle k+1  : o_accum_result valid
             -> batch_norm  (a*acc + b, 28 bit)
             -> ReLU
             -> requant     ((.*M2) >> shift, INT8)
             -> maxpool     (zero latency)
             obuf_we = 1, obuf_waddr = out_row    registered, one behind
```

**In the MLP the accumulator was a register file and `obuf_we` fired in the same
cycle.** It is a BRAM now. Leaving `obuf_we` combinational writes the *previous*
pixel's value into every obuf slot, and the waveform looks completely normal.
`tb_controller` mutation-tests exactly this and fails on the first drained pixel.

### 6.2 Chunking

obuf is 64 rows deep, so the drain runs in chunks of 64 output pixels:

```
drain 64 pixels -> obuf     |  s2mm reads the other ping-pong half
  s2mm group 0 : 128 words  |
  s2mm group 1 : 128 words  |
  s2mm group 2 : 128 words  |
  s2mm group 3 : 128 words  |
next chunk ...
```

784 pixels = 13 chunks (12 full plus one of 16).

### 6.3 Pooling changes the accounting, not the datapath

`maxpool.v` sits after requant and emits one pixel for every four:

```
h = (ow odd) ? max(left, cur) : cur       horizontal pair
oh even : line_buf[ow>>1] <= h            stash
oh odd  : emit max(line_buf[ow>>1], h)    vertical pair
```

Three decisions:

- **Pool on INT8, after requant.** requant is a positive multiply plus a right
  shift, which is monotonic, so `max(requant(a),requant(b)) == requant(max(a,b))`.
  Bit-identical, and it compares 8 bits instead of 28.
- **Line buffer is distributed RAM, not BRAM.** 16 x 256 bits. Asynchronous read
  means **zero added latency**, so the drain keeps its single lead/lag rule. A
  BRAM would add a second one to the most bug-prone part of the design to save a
  few hundred LUTs.
- **Signed compare.** With `relu_en` on the values are non-negative and unsigned
  would agree, but `relu_en` is a per-layer CSR bit. Mutation-tested: unsigned
  fails immediately.

The control side is where the work is. With pooling on:

| | without pool | with pool |
|---|---|---|
| `obuf_we` | every drain cycle | only when `oh` and `ow` are both odd |
| `obuf_waddr` | drained pixels | **emitted** pixels |
| `chunk_full` | 64 drained | 64 **emitted** |
| `chunk_first` | accumulator slot | **output pixel index** |

That last row matters most: `s2mm_base` uses `chunk_first * 2`. Leaving it as an
accumulator slot number would scatter the output across DRAM at 4x the intended
stride.

---

## 7. Every signal's timing, in one table

| signal | driven | consumed | rule |
|--------|--------|----------|------|
| `wbuf_raddr` | `ST_PUSH`, combinational from `push_cnt` | PE row write uses `push_cnt_d1` | address leads by 1 |
| `ibuf_raddr` | `ST_PIX_RD`, combinational | lanes valid in `ST_PIX_WR` | address leads by 1 |
| `ibuf_oob` | registered on the `ST_PIX_RD` edge | masks lanes in `ST_PIX_WR` | mask travels with data |
| `acc_addr` | combinational from `slot` | held across `RD` and `WR` | must not move mid-RMW |
| `i_pe_result` | combinational from ibuf | written in `ST_PIX_WR` | garbage in `RD` is fine |
| `dr_en`/`dr_addr` | combinational in `ST_DRAIN` | data valid next cycle | address leads by 1 |
| `obuf_we`/`obuf_waddr` | registered | writes the data from last cycle | consumer lags by 1 |
| `pool_oh`/`pool_ow` | registered | maxpool sees the pixel one cycle later | same lag as obuf |
| `strm_dest` | follows `mm2s_kind`, not `state_q` | routes the inbound word | prefetched data lands in a different state |

**The single rule:** anything that must track the current state for immediate
downstream use is combinational; anything compensating for pipeline latency is
registered. Several past bugs in this project were this exactly backwards.

---

## 8. What was changed, and why

### 8.1 `accumulator.v` — FSM removed

**Was:** a 2-state FSM with `acc_rdy`, `addr_q`, `pe_q`.
**Now:** no FSM, no flip-flops. The controller drives `acc_ph` directly.

Why: the read-modify-write sequence is part of the compute loop, so hiding it in
a second state machine split the loop across two files. With `acc_ph` exposed,
the whole loop is visible in one place. The module's only state is the BRAM.

It also carried an outright elaboration error — `pe_q` was declared
`ROW_SIZE*PE_OUT_WIDTH` wide in a module that has no `ROW_SIZE` parameter.

### 8.2 `dma.v` — 10 bits to 13

`mm2s_len` at 10 bits truncates a 3,136-word request to `3136 mod 1024 = 64` and
**still pulses `done`.** Demonstrated: at `LEN_W=10` the DMA delivers 64 words
for Conv1_1's input and 128 for Conv1_2's, with no error of any kind.

`LEN_W` is now one parameter so the next change is one line.

### 8.3 `pe_array_hier.v` — a fatal silent bug

```verilog
localparam OUTPUT_WIDTH = $clog2(COL_SIZE) + (DATA_WIDTH*2)   // 5 + 16 = 21
                          ^^^^^^^^^^^^^^^^  should be ROW_SIZE  // 3 + 16 = 19
```

The adder tree sums **ROW_SIZE** products, so the growth is 3 bits. With 21,
`o_result` was 672 bits against `core.v`'s 608-bit `pe_result`: every lane
misaligned, top two bits of each undriven.

**Harmless at 32x32 where `ROW_SIZE == COL_SIZE`, fatal at 8x32.** This is the
*second* bug of exactly this shape in this exact file — the first was `i_weight`
declared `ROW_SIZE` wide but indexed by column. When a width expression names a
dimension, check it against what the hardware actually sums.

### 8.4 `controller.v` — rewritten

- `ig_max` deleted; three reduction counters wrap against their own bounds.
- Textbook names throughout (`ft`, `ct`, `fh`, `fw`, `oh`, `ow`).
- Row streaming: input loading moved from once per layer into the `oh` loop.
- Batch loop deleted (see 8.6).
- Chunked drain with one s2mm burst per output channel group.
- Weight prefetch moved onto the last row sweep, with a `single_row` exception.

### 8.5 Odd dimensions broke the emitted-pixel count

Conv3 pools 7x7 to 3x3. The last drained pixel `(6,6)` is one that **does not
emit**, so the emitted-pixel counter had already moved past the final emission
and `out_row + 1` over-counted by one. Every even shape — 4x4, 8x8, 14x14,
28x28 — hides this.

Fix: `out_row` is a **count**, not a last index, with one spare bit so it can
reach `OB_DEPTH`. `9x9 -> 4x4` is now in the regression set.

### 8.6 Batch (N) removed

In the MLP the batch loop kept the accumulator at 32 registers. In the CNN the
pixel loop took that role, and `N` and `(oh,ow)` are the same kind of axis. With
`img` outermost the cost is exactly `B x` — identical to replaying the CSR
program — so the FSM loop bought nothing over a PS-level loop.

Fusing `N` into the pixel loop *would* pay, but needs `B*OH*OW` accumulator
slots: 64 BRAM36 instead of 32 at B=2, plus B x ibuf. Roughly **31% of the
device to buy ~2%**, because `P = 784` has already amortised the weights to
nothing everywhere except Affine.

Batch now lives at the CSR-program level: change `in_base`, replay.

### 8.7 A DMA request queue was investigated and rejected

The initial reasoning — "`ST_ROW_REQ` waits 64 cycles doing nothing" — was
wrong. During that wait the DMA is streaming the weight tile, which is
productive work. **Queueing DMA requests behind other DMA requests gains nothing
on a single-port memory that moves one word per cycle.**

Measurement settled it: the port is busy 76-90% of every layer. What actually
helped was moving the weight prefetch onto the **last row sweep**, the one
stretch with no next row to fetch. Worth 2.8%, and `dma.v` did not change.

That change has a trap of its own. A layer with `OH == 1` (Affine) has no sweep
to hide behind, and moving the prefetch there made it **7% slower** by
uncovering `ST_PUSH`. The `single_row` condition splits the two placements — a
structural condition, not a tuned constant.

---

## 9. How this is verified

Every module has a standalone testbench, and **every testbench is
mutation-tested**: the DUT is deliberately broken and the test must fail. A test
that has never failed has not been shown to test anything.

| testbench | coverage | mutants caught |
|-----------|----------|----------------|
| `tb_accumulator` | 384 comparisons | addend dropped; `acc_first` ignored |
| `tb_dma_len` | 6 burst lengths | 10-bit width silently truncates |
| `tb_maxpool` | 10,688 comparisons | unsigned compare; vertical pair dropped; wrong emit parity; stash on wrong row |
| `tb_controller` | 11 layer shapes | `obuf_we` same-cycle; emit condition; row-request handshake |

`tb_controller` covers all six real layers plus drain-chunk boundaries (64, 100,
128 pixels) and odd-dimension pooling (7x7, 9x9), and checks nine invariants
including that no buffer address ever exceeds the depth of the IP behind it.

One mutant was **not** caught and was confirmed equivalent, not a gap:
`chunk_first + out_row` versus `chunk_first + OB_DEPTH` produce identical values
in every reachable state, because non-final chunks always close with
`out_row == OB_DEPTH` and the final chunk's update is immediately reset.

The whole `tb_top` hierarchy elaborates with zero warnings. What is **not** yet
verified is data correctness end to end; that needs the Python golden model.
