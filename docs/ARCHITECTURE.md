# CNN accelerator — module map and signal dictionary

Companion to the other two documents, not a replacement:

| file | answers |
|------|---------|
| `DESIGN_NOTES.md` | project rules, parameters, per-layer mapping, CSR map, traps |
| `DATAFLOW.md` | **why** the loops and layouts are what they are, worked cycle traces |
| `ARCHITECTURE.md` (this) | **what** each module and signal is, and where every byte goes |

Status: all six layers pass bit-exact in `tb_top`. See section 8.

---

## 1. The machine in one paragraph

`top.v` is a **layer** engine, not a network engine. It is given ten CSR
registers describing ONE layer, plus a DRAM that already holds the weights, the
BN constants and the input activations. On `start` it streams that layer's
weights and inputs in, computes `OH*OW*FN` results into an on-chip accumulator,
pushes them through BN → ReLU → requant → maxpool, and writes INT8 activations
back to DRAM. Then it pulses `done`. A whole network is that program replayed
six times with different CSR values; `tester.v` is the thing doing the replaying.

The PE array itself is just a **vector-matrix multiplier**: 8 bytes in, an
8x32 weight tile held in registers, 32 partial sums out. It has no idea what the
bytes mean. Everything that makes it a convolution lives in the address
generator inside `controller.v`.

---

## 2. Hierarchy

```
tester.v                  models the PS. Owns the DRAM (blk_mem_gen 32b x 65536)
  |                       and replays a CSR program stored in it at PROG_BASE.
  +-- top.v               the accelerator proper
        +-- dma.v         one linear burst at a time: mm2s (read), s2mm (write)
        +-- core.v        datapath + control
              +-- controller.v      the only FSM. 20 states, all loop counters
              +-- input_buffer.v    ibuf : NB_IN=2 banks x 32b x 32, ping-pong
              +-- weight_buffer.v   wbuf : NB_W=8 banks x 32b x 32, ping-pong
              +-- bank_unpack.v     x2 : bank words -> flat byte lanes
              +-- pe_array_hier.v   8 rows x 32 cols, weight-stationary
              |     +-- pe_col.v          one output channel
              |           +-- PE.v        multiplier + weight register
              |           +-- pe_adder_tree.v
              +-- accumulator.v     32 lanes x 24b x 1024 slots, 1 BRAM per lane
              +-- bn_regfile.v      384 channels of (A,B) as 12 groups of 32
              +-- batch_norm.v      (acc * A >> s1) + B
              +-- ReLU.v
              +-- requant.v         (x * M2) >> s2, saturate to INT8
              +-- maxpool.v         2x2 stride 2, line buffer in distributed RAM
              +-- output_buffer.v   obuf : NB_OUT=8 banks x 32b x 64, ping-pong
```

`pe_array.v`, `adder_tree.v`, `rca.v`, `full_adder.v`, `ha_adder.v`, `mux2.v`,
`multiplier.v` and `batch_norm_array.v` are Task-1 leaf cells and alternates;
the active path is the `_hier` one.

---

## 3. Widths, and what each one counts

The two 8s mean different things, and this is the single most confusing thing in
the design:

```
ROW_SIZE   = 8    a COUNT of values summed together   (PE rows)
DATA_WIDTH = 8    the WIDTH of one value              (INT8)
one ibuf row = ROW_SIZE * DATA_WIDTH = 64 bit = 8 bytes = eight numbers
```

| name | value | derivation | meaning |
|------|-------|-----------|---------|
| `ROW_SIZE` | 8 | | PE rows = reduction width |
| `COL_SIZE` | 32 | | PE columns = output channels in parallel |
| `MEMORY_WIDTH` | 32 | | one DRAM / buffer word |
| `NB_IN` | 2 | `ROW_SIZE*8/32` | ibuf banks |
| `NB_W`, `NB_OUT` | 8 | `COL_SIZE*8/32` | wbuf / obuf banks |
| `ROW_BIT` | 3 | `clog2(ROW_SIZE)` | PE row index |
| `PE_OUT_WIDTH` | 19 | `ROW_BIT + 16` | one tile's partial sum. **clog2(ROW_SIZE), not COL_SIZE** |
| `ACCUM_WIDTH` | 24 | `PE_OUT_WIDTH + 5` | accumulator lane |
| `A_W`, `B_W` | 4, 20 | | BN scale, BN offset |
| `BN_WIDTH` | 28 | `ACCUM_WIDTH + A_W` | batch_norm output |
| `REQ_W` | 8 | | requant output, back to INT8 |
| `IB_A_BIT` | 5 | | ibuf depth 32, holds W input columns (28 used) |
| `WB_A_BIT` | 5 | | wbuf depth 32, one tile is ROW_SIZE rows (8 used) |
| `OB_A_BIT` | 6 | | obuf depth 64, one drain chunk (64 used) |
| `ACC_A_BIT` | 10 | | 1024 accumulator slots (784 used) |
| `LEN_W` | 13 | | burst length. 6272 needs 13 bits; 10 silently truncates |
| `LB_A_BIT` | 4 | | maxpool line buffer, OW/2 (14 used) |

---

## 4. Signal dictionary

### 4.1 Host / CSR — `tester.v` → `top.v`

| signal | dir | width | role |
|--------|-----|-------|------|
| `csr_we` | in | 1 | one-cycle write strobe |
| `csr_addr` | in | 4 | register index. 0..9 are real; `4'hE` and `4'hF` are program opcodes consumed by `tester.v` and never reach the core |
| `csr_data` | in | 32 | value |
| `done` | out | 1 | one-cycle pulse, layer finished |

CSR contents are in `DESIGN_NOTES.md` section 7. Register 7 is START.

### 4.2 DRAM — `top.v` → `tester.v`

`dram_en`, `dram_we`, `dram_addr[15:0]`, `dram_wdata[31:0]`, `dram_rdata[31:0]`.
Single port, one word per cycle, read latency 1. **16 bits is a hard ceiling of
65,536 words, and the design uses 54,960 of them.**

### 4.3 DMA requests — `controller.v` ↔ `dma.v`

| signal | dir | role |
|--------|-----|------|
| `mm2s_req` | ctrl → dma | **level**, held until `mm2s_done`. It stays high through its own done cycle, so any behavioural DMA model must mirror the `S_IDLE` guard in `dma.v` or it starts the same burst twice |
| `mm2s_base` | ctrl → dma | first DRAM word |
| `mm2s_len` | ctrl → dma | words. Driven from `mm2s_kind`: `BN_WORDS` (432), `row_words`, or `TILE_WORDS` (64) |
| `mm2s_done` | dma → ctrl | one-cycle pulse |
| `s2mm_req/base/len/done` | | same shape, for writes |

`mm2s_kind[1:0]` is an internal register, **not** the state: `0` weight tile,
`1` input row, `2` BN constants. `strm_dest` follows the load, not the FSM
state, because a prefetch outlives the state that issued it.

### 4.4 Fill side — `dma.v` → buffers

| signal | role |
|--------|------|
| `strm_vld`, `strm_data[31:0]` | one word per cycle |
| `strm_idx[LEN_W-1:0]` | its index **inside the burst** — the write address is derived from this |
| `wbuf_we[7:0]`, `ibuf_we[1:0]` | per-bank write enables; the bank is `strm_idx mod NB` |
| `wbuf_waddr`, `ibuf_waddr` | **two separate signals.** ibuf has 2 banks and wbuf has 8, so one DRAM word lands in a different row of each. A single `strm_waddr` was wrong |
| `strm_wdata[31:0]` | the word itself, common to both |
| `bn_rf_we`, `bn_rf_waddr[8:0]` | BN table load, 432 words |

### 4.5 Ping-pong selects

| signal pair | swaps at | why |
|-------------|----------|-----|
| `wbuf_wr_sel` / `wbuf_rd_sel` | `ST_TSWAP` | once per weight tile |
| `ibuf_wr_sel` / `ibuf_rd_sel` | `ST_RSWAP` | once per input row. **Load-bearing, not an optimisation**: without it the row load and the pixel sweep serialise and every layer doubles |
| `obuf_wr_sel` / `obuf_rd_sel` | `ST_OUT_REQ` **and `wb_grp == 0`** | once per CHUNK, not per burst. `ST_OUT_REQ` is entered 4 times per chunk, one per output channel group; swapping on each handed the read side to the empty half and groups 1..3 streamed zeros |

Ping-pong needs two separate BRAM IP instances. One deeper instance cannot write
one half while reading the other.

### 4.6 Read side — buffers → PE

| signal | timing | role |
|--------|--------|------|
| `wbuf_raddr[4:0]` | leads | weight row during `ST_PUSH` |
| `pe_w_en`, `pe_row_addr[2:0]` | **lags `wbuf_raddr` by one** | writes that row into the PE registers. `ST_PUSH` runs `ROW_SIZE+1` cycles for exactly this reason |
| `ibuf_raddr[4:0]` | leads, driven at `ST_PIX_RD` | input column `ow + fw - pad`, truncated to 5 bits |
| `ibuf_oob` | **registered**, arrives with the data | forces all 8 lanes to zero: `ibuf_lanes = ibuf_oob ? 0 : ibuf_raw` in `core.v` |

### 4.7 Address generation (internal to `controller.v`)

| wire | expression | note |
|------|-----------|------|
| `in_h` | `oh_cnt + fh_cnt - pad` | 10-bit; `-1` wraps to 1023 |
| `in_w` | `ow_cnt + fw_cnt - pad` | same |
| `row_oob` | `in_h > h_max` | one unsigned compare catches both ends at once |
| `col_oob` | `in_w > w_max` | |
| `row_step` | `(w_max+1) * NB_IN` | words per input row |
| `ct_base` | `in_base + ct*ct_stride` | an accumulator, no multiplier |
| `row_base` | `ct_base + (oh+fh-pad)*row_step` | set to `row_base0` at `ST_TSWAP`, then `+= row_step` per output row |
| `row_base0` | `ct_base + fh_fwd - pad_back` | **both products formed unsigned, then subtracted.** A signed multiply mixed with the unsigned `ct_base` makes the whole expression unsigned and `fh-pad = -1` becomes `+15`; `$signed()` on the operands does not help |
| `ft_base`, `grp_base` | accumulators of `og_stride` | s2mm destination, no multiplier |

Loop counters, innermost first: `fw_cnt` → `fh_cnt` → `ct_cnt` → `ft_cnt`, with
`oh_cnt` / `ow_cnt` sweeping inside each tile and `slot` = the accumulator
address = the output pixel. There is no flat `ig_max`; each counter wraps
against its own bound.

```verilog
acc_first  = (ct_cnt==0) && (fh_cnt==0) && (fw_cnt==0);
tile_last  = (ct_cnt==ct_max) && (fh_cnt==fh_max) && (fw_cnt==fw_max);
single_row = (oh_max == 0);      // Affine: no sweep to hide a prefetch behind
```

### 4.8 Accumulator

| signal | role |
|--------|------|
| `acc_en` | enable. **Never high with `dr_en`** — shared BRAM port |
| `acc_ph` | 0 = read (`ST_PIX_RD`), 1 = write back (`ST_PIX_WR`) |
| `acc_first` | first tile of this pixel: store `pe_result`, do not add |
| `acc_addr[9:0]` | = `slot`. Must hold across both phases; that is free, because the PE array is combinational, so holding `ibuf_raddr` holds `pe_result` |
| `dr_en`, `dr_addr[9:0]` | drain read. `o_accum_result` is valid **one cycle later** |

The module has no FSM and no flip-flops. A single-port BRAM cannot read and
write in one cycle, so the *controller* owns the two-phase sequence and the
whole loop stays visible in one state machine.

### 4.9 Post path — accumulator to DRAM

```
acc_result[32 x 24b]
   -> batch_norm   (acc * A >> bn_shift) + B     A,B from bn_regfile
   -> ReLU                                        relu_en
   -> requant      (x * rq_mult) >> rq_shift      saturate to INT8
   -> maxpool      2x2 stride 2, or bypass        pool_en
   -> obuf         8 banks x 32b, 4 channels per word
   -> s2mm         one burst per output channel group
```

| signal | role |
|--------|------|
| `bn_group_base[8:0]` | `{(bn_group + ft_cnt)[3:0], 5'b0}` — which 32-channel group of the BN table |
| `bn_shift[1:0]` | BN `s1`, **per layer, from CSR8[14:13]**. It used to be a compile-time `parameter S1 = 2`; the CNN's conv layers want `0,2,3,2,3` and forcing 2 costs 17 points of integer accuracy |
| `rq_mult[3:0]`, `rq_shift[3:0]` | requant `M2` and `s2` |
| `bn_en`, `relu_en` | CSR0[17], CSR0[18] |
| `pool_en`, `pool_vld`, `pool_oh[7:0]`, `pool_ow[7:0]` | maxpool control. Pooling happens **after** requant, on INT8: requant is a multiply by a positive constant and a shift, so it is monotonic and `max(rq(a),rq(b)) == rq(max(a,b))`. Bit-identical, and it compares 8 bits instead of 28 |
| `obuf_we`, `obuf_waddr[5:0]` | **registered one behind `dr_en`** |
| `wb_grp[1:0]` | which of the 4 output channel groups s2mm is reading |
| `wide_out` | CSR0[19]. 32-bit logits, one flat burst, `ST_CHUNK_END` goes straight to `ST_DONE` |
| `wide_half_sel` | which 16 channels this obuf row carries. **Control only** |
| `wide_half_sel_d1` | the same bit registered to match `obuf_we`. **The datapath mux in `core.v` must use this one** — consuming the live bit emitted the upper half first and the lower half second, right values in the wrong order |

`out_row` is a **count, not a last index**, with one spare bit so it can reach
`OB_DEPTH`. Conv3 pools 5x5 to 2x2, so the last drained pixel does not emit and
"last index + 1" is wrong. Every even shape hides this.

---

## 5. FSM

| state | what happens |
|-------|--------------|
| `ST_IDLE` | wait for the CSR start pulse; reset every counter and base |
| `ST_BN_REQ` / `ST_BN_WAIT` | load 432 BN words from `BN_DRAM_BASE` |
| `ST_TILE_REQ` / `ST_TILE_WAIT` | blocking load of the FIRST weight tile. Entered once per layer; every later tile arrives by prefetch |
| `ST_TSWAP` | hand the tile to the PE side; reset `oh`/`ow`/`slot`; `row_base <= row_base0`. Prefetches the next tile **if `single_row`** |
| `ST_PUSH` | `ROW_SIZE+1` cycles, wbuf → PE weight registers |
| `ST_ROW_REQ` / `ST_ROW_WAIT` | blocking load of this sweep's first input row, **skipped entirely when `row_oob`** |
| `ST_RSWAP` | swap ibuf; prefetch the next row, or on the last row prefetch the next weight tile instead |
| `ST_PIX_RD` | `ibuf_raddr` out, accumulator read |
| `ST_PIX_WR` | ibuf data arrives → `pe_result`; accumulator write. **2 cycles per pixel, always** — no fast path for `acc_first`, because the ibuf read latency is 1 and the input DMA needs 2 words per pixel anyway |
| `ST_ROW_END` | wait for the row prefetch, then next `oh` |
| `ST_TILE_END` | advance `fw` / `fh` / `ct`, or go and drain |
| `ST_DRAIN` | accumulator → post path → obuf, pipelined |
| `ST_DR_TAIL` | one extra cycle: the last obuf write lags |
| `ST_OUT_REQ` / `ST_OUT_WAIT` | s2mm one channel group of this chunk |
| `ST_CHUNK_END` | next group / next chunk / next `ft` / finish |
| `ST_DONE` | pulse `done` |

---

## 6. Data flow, end to end

### 6.1 Memory layouts

**Activations — `(C/ROW_SIZE, H, W, ROW_SIZE)`, channel-group major.**

```
word(ct, h, w) = base + ct*ct_stride + (h*W + w)*NB_IN
ct_stride      = H*W*NB_IN
```

One input row of one channel group is a single linear burst, which is all
`dma.v` can do. Pure HWC would scatter a row with stride `C/ROW_SIZE` and could
not be fetched at all.

**Weights — `(ft, ct, fh, fw)`, `fw` fastest, 64 words per tile.**

```
word 8r + b, byte j  =  W[fn = 4b+j][c = ct*ROW_SIZE + r][fh][fw]
```

A mismatch here is bit-exact failure with no visible cause: the waveform looks
correct.

**BN table — 432 words.** A packed 8 channels per word at `grp*4 + j`; B one per
word at `48 + grp*32 + lane`. The full table must be emitted with unused groups
zeroed, because the b-words are addressed as `waddr - 48`.

### 6.2 The loop

```
for ft:                            output-channel tile  (COL_SIZE at a time)
  for ct:                          input-channel tile   (ROW_SIZE at a time)
    for fh:
      for fw:
        load weight tile (ft,ct,fh,fw)      64 words
        PUSH -> PE                          ROW_SIZE+1 cycles
        for oh:                             output row
          load input row (oh+fh-pad) of group ct   W*NB_IN words, prefetched
          for ow:                           output column
            ST_PIX_RD / ST_PIX_WR           2 cycles, accumulator RMW
  drain the COL_SIZE channels of every pixel, one obuf chunk at a time
```

Only **summed** axes may sit on PE rows, because the adder tree adds all
`ROW_SIZE` products unconditionally. `c` goes on the rows; `(fh,fw)` will not fit
as well, so it becomes separate passes that accumulate — which is what the
read-modify-write accumulator exists for. The pixel loop is innermost, which is
what makes weight-stationary actually pay off.

### 6.3 Row streaming

Hold `(ct,fh,fw)` fixed and sweep the pixels. `fh` is fixed for the whole sweep,
so the input **row** is fixed too and only the column moves. Only one input row
of one channel group is ever live:

```
ibuf depth = W       28 for the widest layer, against a depth of 32
```

instead of `H*W*C/ROW_SIZE` = 3136 rows. It is nearly free because of an exact
match: one ibuf row is `NB_IN = 2` DRAM words and one pixel takes 2 cycles, so
loading row `oh+1` hides completely under the pixel sweep of row `oh`.

### 6.4 Padding is two separate things

- **row out of range** (`oh+fh-pad` outside `[0,H)`) — the whole row is padding.
  The load is *skipped*, no DRAM traffic, and the mask forces zeros.
- **column out of range** (`ow+fw-pad` outside `[0,W)`) — individual pixels at
  the row ends. `ibuf_oob` masks the lanes.

Both use one unsigned compare, because `-1` wraps to a large value.

### 6.5 The drain

The drain walks the conv output map in raster order, which is exactly what a 2x2
pool wants, so pooling costs no extra pass and no DRAM round trip. One s2mm
burst per output channel group, selected by `wb_grp`; a `ft` tile produces
`COL_SIZE/ROW_SIZE = 4` groups, so a drain chunk emits 4 bursts.

```
s2mm_base = out_base + (ft*4 + g)*og_stride + chunk_first*NB_IN
```

`og_stride` and `out_words` are the **pooled** sizes, so pooling needs no CSR
field beyond `pool_en`.

---

## 7. Timing rules, in one place

**BRAM read latency 1 is the dominant bug source in this design.** The rule is
always the same: the address leads, the consumer lags.

| producer (leads) | consumer (lags) | mechanism |
|------------------|-----------------|-----------|
| `wbuf_raddr` | `pe_w_en` / `pe_row_addr` | `push_cnt_d1` |
| `ibuf_raddr` (`ST_PIX_RD`) | ibuf data (`ST_PIX_WR`) | two states per pixel |
| `ibuf_raddr` | `ibuf_oob` | registered on the `ST_PIX_RD` edge |
| `dr_en` / `dr_addr` | `obuf_we` / `obuf_waddr` | registered one behind |
| `wide_half_sel` (control) | `wide_half_sel_d1` (datapath) | registered one behind |

Combinational vs registered discipline: anything that must track the current
state for immediate downstream use is combinational; anything compensating for
pipeline latency is registered. Several past bugs were this backwards.

---

## 8. Verification status

All six layers pass bit-exact in `tb_top` against `quant_cnn.py`'s integer
model, in one run of one CSR program:

| layer | cycles | cumulative |
|-------|--------|-----------|
| Conv1_1 | 34,060 | 34,060 |
| Conv1_2 | 129,822 | 163,882 |
| Conv2_1 | 84,386 | 248,268 |
| Conv2_2 | 145,106 | 393,374 |
| Conv3 | 90,322 | 483,696 |
| Affine | 10,430 | 494,126 |

`all_done` at **494,322 cycles = 4.94 ms @ 100 MHz.** `>>> PASS : bit-exact (928 words)`.
Identical cycle counts in Icarus Verilog and Vivado 2022.1 XSim.

The golden set covers only the regions still live at the end of the program,
because the activation ping-pong overwrites each layer's output two layers
later: Conv3's map at ACT_A, Conv2_2's at ACT_B, and the 16 logits at OUT_BASE.
Earlier layers were each verified on their own during bring-up, and
`quant_cnn.py --upto <layer>` reproduces any of those runs.

Module level: `tb_accumulator` 384 comparisons, `tb_maxpool` 10,688,
`tb_controller` 11 layer shapes with 4 mutants caught, `dma` 6 burst lengths.

### Debug tooling

- `quant_cnn.py --upto <layer>` — emit the CSR program up to a layer.
  `--debug-nopool` forces `pool_en=0` on the last layer, which separates a
  reduction bug from a maxpool bug and leaves a map that can be inverted back to
  accumulator values. `--vivado <proj>` stages the three txt files where xsim
  will find them.
- `mkdebug.py` — preload a known-good activation into ACT_A and run ONE
  synthetic layer over it: `--taps center|nopad|full`, `--ct N`.
- `probe.py` / `probe4.py` — identity weights and a no-op BN, so **the output
  byte IS the input byte the hardware fetched**, and the input values encode
  their own coordinates. Reads the address generator out directly.
- `analyze_got.py` — the structure of a mismatch: per row, per column, per
  channel, plus spatial-shift and channel-permutation tests. `tb_top` dumps every
  compared word to `got.txt` for it.
