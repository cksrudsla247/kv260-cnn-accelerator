# `dma.v` S_IDLE Race + Verifying the Untested AXI Paths

**Date:** 2026-09-17
**Symptom:** `tb_top.v` failed 918–922 of its 928 golden words (expected 928/928).

**Summary**

| item | status |
|------|--------|
| `dma.v` S_IDLE race | fixed — `tb_top.v` **928/928 PASS** |
| `axi4_master_dram.v` (AXI4 DDR path) | previously untested → new `tb_axi4_dma.v`, **PASS** (mutation-tested) |
| `axi_lite_csr.v` exposes a 1-cycle `done` pulse | found and fixed (sticky latch) → new `tb_axi_lite_csr.v`, **PASS** (mutation-tested) |
| `top_kv260.v` (full board topology) | previously untested → new `tb_top_kv260.v`; a testbench `disable`-label bug (not RTL) found and fixed → **928/928 PASS** (§7) |

---

## 1. Background

`dma.v` was originally written for a real BRAM with a fixed 1-cycle read latency. To reach DDR over AXI4 it was rewritten as a `dram_rdy`-handshake FSM (`S_IDLE / S_RD_WAIT / S_WR_FETCH / S_WR_ISSUE / S_WR_WAIT`), and `tb_top.v` regressed to 918–922/928. The CSR/address generation in `controller.v`, the `dram` IP output-register setting and `core.v`'s `wb_row_nxt` were all checked and ruled out.

## 2. Root cause

**`dma.v`'s `S_IDLE` re-samples `*_req` on the very cycle it emits its own `*_done` pulse**, but `controller.v` only lowers `*_busy` (→ `*_req`) on the cycle **after** it sees `*_done`. In that one-cycle gap the DMA mistakes the stale request level for a new request and launches a **phantom 1-word transfer using the old burst's base address**. This happens at every group/chunk boundary within a layer and at every layer transition, so Conv1_1's output was already corrupted and the error propagated through the remaining five layers.

### Waveform evidence (reproduced in Icarus Verilog; `cyc` = 100 MHz cycles)

First group boundary (128 words) of Conv1_1 writing to `0xB970`:

```
cyc=73779  dma_state=S_WR_WAIT  w=127  dram_en=1 dram_we=1 addr=b9ef   <- last word of group 0, correct
cyc=73781  dma_state=S_DONE_S
cyc=73782  dma_state=S_IDLE     s2mm_done=1  s2mm_busy=1  s2mm_req=1   <- *** controller still busy=1 ***
cyc=73783  dma_state=S_WR_FETCH w=0   wb_req=1                        <- phantom request starts (stale s2mm_req=1)
cyc=73785  dma_state=S_WR_WAIT  dram_en=1 dram_we=1 addr=b970         <- rewrites group 0 address (old s2mm_base)
cyc=73786  s2mm_busy=1                                                <- only now does the controller set up group 1
cyc=73789  addr=bf91  (w=1)                                           <- w is already 1, mixed with group 1 base (bf90)+1
```

### Code

`controller.v` — `*_busy` drops on the edge **after** it sees `*_done`:

```verilog
// controller.v : 473-485
always @(posedge clk or posedge rst) begin
    if (rst) begin
        s2mm_busy <= 1'b0; ...
    end else if ((state_q == ST_OUT_REQ) && !s2mm_busy) begin
        s2mm_busy  <= 1'b1;
        s2mm_addr  <= wide_out ? out_base : (grp_base + ...);
        s2mm_words <= wide_out ? out_words : chunk_words;
    end else if (s2mm_done) begin
        s2mm_busy <= 1'b0;      // takes effect the edge after s2mm_done is seen
    end
end
```

`dma.v` (before the fix) — `S_IDLE` re-checks `*_req` on the same cycle it emits `*_done`:

```verilog
// dma.v : 82-95 (before)
case (state)
S_IDLE: begin
    w<=0;
    if (mm2s_req) begin
        ...
    end else if (s2mm_req) begin   // <- stale req taken as a new request
        wb_req <= 1'b1;
        wb_idx <= {LEN_W{1'b0}};
        state  <= S_WR_FETCH;
    end
end
```

### Why the old `dma.v` passed

The previous `dma.v` had a guard in `S_IDLE` that blocked exactly this race:

```verilog
S_IDLE: begin
    b<=0; w<=0; idx<=0; ra_b<=0; ra_w<=0;
    if (mm2s_done || s2mm_done) begin
        // do nothing - guard
    end else if (mm2s_req) begin
    ...
```

The guard was **lost in the AXI rewrite** — the direct cause of the 928 → 918–922 regression.

## 3. Fix

**File:** `rtl/dma.v`, `S_IDLE` case

```verilog
S_IDLE: begin
    w<=0;
    // *_req is a level held by the controller until it sees our
    // *_done pulse; busy/req only drops the cycle AFTER that, so
    // on the very cycle we assert *_done and land back in S_IDLE,
    // the old request is technically still asserted. Without this
    // guard that stale level looks like a brand-new request and
    // we launch a 1-word phantom transfer at the OLD base/index
    // before the controller reprograms it for the real next
    // burst - corrupting one word at every mm2s/s2mm boundary.
    if (mm2s_done || s2mm_done) begin
        // just finished; wait one cycle for req to actually drop
    end else if (mm2s_req) begin
        dram_en   <= 1'b1;
        dram_we   <= 1'b0;
        dram_addr <= mm2s_base;
        state     <= S_RD_WAIT;
    end else if (s2mm_req) begin
        wb_req <= 1'b1;
        wb_idx <= {LEN_W{1'b0}};
        state  <= S_WR_FETCH;
    end
end
```

In one line: restore the old "if you just finished, start nothing this cycle — wait one beat" guard.

## 4. Verification — `tb_top.v` (BRAM-direct path)

Also confirmed that the CSR program encoding (`csr_addr=9` etc. in `dram.txt`) and the ping-pong address reuse (`0xB970` / `0xD1F0`) are intentional in `quant_cnn.py` and not bugs (`out_base = ACT_A if (li % 2 == 0) else ACT_B`, `quant_cnn.py:449`).

The full project RTL (dram IP, tester, controller, core, dma) compiled in Icarus Verilog and `tb_top.v` run to completion:

```
$ awk '{if ($2 != $3) c++} END{print "mismatches:", c+0, "/", NR}' got.txt
mismatches: 0 / 928
```

**928/928 PASS.** Per-layer cycles (this Icarus run):

| layer | completes at (cumulative cycles) |
|-------|---------------------|
| Conv1_1 | ~100,000 (includes the 65,536-cycle DRAM load) |
| Conv1_2 | ~230,000 |
| Conv2_1 | ~315,000 |
| Conv2_2 | ~460,000 |
| Conv3   | ~550,000 |
| Affine  | ~560,000+ |

## 5. New test — `tb_axi4_dma.v` (AXI4 path)

### Why

`tb_top.v` only tests `dma.v` **wired directly to `tester.v`'s BRAM** (fixed 1-cycle latency). On the KV260 the real path is `dma.v` → **`axi4_master_dram.v` (AXI4 master) → the PS DDR HP port**, and that path was instantiated in `top_kv260.v` but **had never been run by any testbench**. The whole reason `dma.v` was rewritten as a variable-latency handshake was this AXI path — the most important part was untested.

### File

**`sim/tb_axi4_dma.v`** (new)

- Drives `dma.v` + `axi4_master_dram.v` directly through a minimal stub, no controller.
  - s2mm: answers `wb_req/wb_idx` with `wb_data` one cycle later (same timing contract as `core.v`'s obuf).
  - mm2s: captures `strm_vld/strm_data/strm_idx` into a local memory.
- A hand-written **variable-latency AXI4 slave BFM** (stands in for the PS DDR HP port):
  - AR/AW/W `READY` delayed 0–5 random cycles per transaction.
  - R/B `VALID` delayed 0–5 random cycles.
  - **`AWREADY` and `WREADY` arrive on different cycles, in either order** — exactly the case `axi4_master_dram.v`'s independent `aw_done`/`w_done` latches exist for.
- 50 rounds (length 1–37 words, random base) + 10 back-to-back rounds (no gap between requests — checks the S_IDLE race under variable AXI latency too): **write → read back → compare**.

### Result

```
>>> PASS : axi4_master_dram bit-exact over 708 words, 50 rounds
```

### Mutation test (does the testbench actually detect faults?)

One line in `axi4_master_dram.v`'s read-data capture deliberately broken:

```verilog
dram_rdata <= dram_rdata;  // BUG injected - assigns itself instead of m_axi_rdata
```

Same testbench:

```
>>> FAIL : 708/708 word mismatches
```

**All 708 words flagged — the testbench really detects the fault.** (By project convention every testbench is mutation-tested.)

## 6. `axi_lite_csr.v` — a 1-cycle `done` pulse exposed as-is

### Problem

`controller.v`'s `done` is **exactly one cycle wide**:

```verilog
// controller.v
always @(posedge clk or posedge rst) begin
    if (rst) done <= 1'b0;
    else     done <= (state_q == ST_DONE);
end
```

and `axi_lite_csr.v` passed it straight to the AXI-Lite read data:

```verilog
// axi_lite_csr.v (before)
s_axi_rdata <= (s_axi_araddr[5:2] == DONE_REG) ? {31'd0, done} : 32'd0;
```

A 10 ns pulse at 100 MHz has essentially zero chance of being sampled by a PS polling loop over AXI-Lite. `tb_top.v` and `tb_axi4_dma.v` never touch this register, so it went unnoticed until `top_kv260.v` was driven for the first time.

### Fix

**File:** `rtl/axi_lite_csr.v` — wrap `done` in a sticky latch that holds until the next layer's start (`csr_addr == 7` write):

```verilog
// controller.v's `done` is a ONE-CYCLE pulse (done <= state_q==ST_DONE).
// At 100 MHz that is a 10 ns window; a PS polling loop reading this
// register over AXI-Lite has no realistic chance of ever sampling that
// exact cycle. Latch it here so software sees a level that stays high
// until it programs the NEXT layer (csr_addr 7 = start_pulse), which is
// exactly the point software has already observed the previous done and
// moved on - same convention tester.v uses internally (T_WAIT waits for
// the pulse, T_F0 immediately starts the next program's CSR writes).
reg done_latch;
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn)
        done_latch <= 1'b0;
    else if (done)
        done_latch <= 1'b1;
    else if (csr_we && csr_addr == 4'd7)
        done_latch <= 1'b0;
end
```

and the read path returns `done_latch` instead of `done`.

### Verification — `sim/tb_axi_lite_csr.v` (new)

`axi_lite_csr.v` driven by an AXI4-Lite master BFM:
- AW and W on independent, randomised cycles and order (`fork/join`).
- Random back-pressure on BREADY/RREADY.
- 200 random register writes (addresses 0–9 cycling, plus 20 back-to-back with no gap), captured and compared in order.
- Read the `done` register (index 0xF, byte address 0x3C) and check every other address returns 0.

```
>>> PASS : axi_lite_csr bit-exact over 200 writes + readback checks
```

Mutation test (`DONE_REG` quietly changed from `4'hF` to `4'hE`, breaking the done-register decode):

```
READ MISMATCH: done=1 expected 1, got 00000000
>>> FAIL : 1 error(s)
```

**Caught.**

> Two bugs were in the testbench itself, not the DUT. First, it missed the fast path where BVALID/RVALID is already high **before** BREADY/RREADY is raised (AW and W accepted on the same cycle): it always waited one `@(posedge clk)` before checking `while(!bvalid)`, and bvalid had come and gone in between, deadlocking the testbench. Fixed by checking immediately after raising ready, then waiting. Second, the register index was not shifted (`<<2`) into a byte address, so every access hit the wrong register. After both fixes: PASS.

## 7. New test — `tb_top_kv260.v` (full board topology)

### Why

`tb_axi4_dma.v` and `tb_axi_lite_csr.v` verify each AXI adapter **on its own**. `top_kv260.v`, which is what actually goes on the KV260, wires both of them together with `core.v`, and that combination had never been simulated.

### Structure

**`sim/tb_top_kv260.v`** (new)

- Instantiates the whole `top_kv260`. The testbench plays the PS:
  - As an **AXI4-Lite master** it replays the CSR program encoded in `dram.txt`, in the same order `tester.v` does, but as real AXI-Lite writes.
  - After each start write (`csr_addr == 7`) it reads the `done` register in a **realistic polling loop every 37 cycles** (a prime period chosen so it cannot line up with the hardware by accident).
- An **AXI4 DDR slave model** (the PS HP port), the same variable-latency BFM as `tb_axi4_dma.v`, preloaded with all of `dram.txt`.
- After all 6 layers, the DDR model contents are compared directly against `gold.txt` / `gold_addr.txt` (the same way the PS would read its own DDR).
- Progress is written periodically to a small heartbeat file (to avoid the fake-hang problem from stdout buffering — §8).

### Result — a hang right after Layer 6 completes

Replaying all six layers, **the CNN computation for Layers 1–6 completes correctly every time, but the simulation stops making progress right after Layer 6's (Affine, the last layer) `core.done` pulse.** Two independent full replays reproduced the hang at exactly the same point — deterministic, not chance.

```
cyc=1999510 ctrl=18 ...
cyc=1999511 ctrl=19 ...                         <- ST_DONE
cyc=1999512 ctrl=0  ... core_done=1             <- done pulse, Layer 6 completes correctly
cyc=1999513 ctrl=0  ... core_done=0             <- nothing changes after this
cyc=2019514 >>> STALL WATCHDOG: no state change for >20000 cycles, stopping
```

**Hypotheses tested and rejected:**

1. **"Layer 6 itself is broken"** — rejected. Jumping `ptr` straight to Layer 6's entry and replaying only that layer completes cleanly in about 43,000 cycles. Layer 6's control logic (`controller.v`) is fine.
2. **"A false stall from the polling cap"** — rejected, and this one was a testbench bug of my own. A debug cap of 3,000 polls in `wait_done` was exceeded by Layer 2 alone, which legitimately takes 545,000+ cycles under AXI overhead, and looked like a hang. With the cap removed (unbounded polling, as in the real testbench) it was not a hang.
3. **"The CSR program's end marker (0xE) is never found"** — rejected. Parsing `dram.txt` from `PROG_BASE (0xEA80)` shows the end marker (`0000000e`, ptr `0x0eaf8`) immediately after Layer 6's start command (`0xF`, ptr `0x0eaf6`).
4. **An AXI4 protocol fault in `axi4_master_dram.v` / `dma.v`** — rejected. An isolated stress version of `tb_axi4_dma.v` with wider random delays (AR ready 0–11, AW/W gap 0–7, B 0–11 cycles) and 5,000 rounds (94,224 words) passed, and its watchdog (no state change for 5,000 cycles) never fired.
5. **Polling `axi_lite_csr.v` deadlocks** — rejected. 50,000 back-to-back reads of the done register passed with no hang.

(The two stress testbenches were scratch tests and are not in this repository.)

### The real root cause — a Verilog `disable` bug in the testbench, not the RTL

Found by adding the AXI-Lite channel signals (`s_axi_ar/r/aw/w/b` valid/ready, and `axi_lite_csr.v`'s internal `rstate`/`wstate`/`done_latch`) to the watchdog, and logging exactly which `ptr`/`e_addr`/`e_data` the `prog_loop` reads on every iteration.

The log shows everything correct up to Layer 6's done poll:

```
cyc=1956421 lyr=5 ptr=0x0000eaf6 word=0000000f e_addr=f e_data=00000001   <- Layer 6 start pulse
cyc=1999519 lyr=6 ptr=0x0000eaf8 word=0000000e e_addr=e e_data=00000000   <- end marker (0xE) found correctly
cyc=1999519 lyr=6 ptr=0x0000eafa word=00000000 e_addr=0 e_data=00000000  <- ...but the loop keeps going
cyc=1999522 lyr=6 ptr=0x0000eafc word=00000000 e_addr=0 e_data=00000000
...
cyc=2008086 lyr=6 ptr=0x00010000 word=xxxxxxxx e_addr=x e_data=xxxxxxxx  <- runs past DRAM_DEPTH (0x10000) into X
...
cyc=2242208 lyr=6 ptr=0x00033d1c word=xxxxxxxx e_addr=x e_data=xxxxxxxx  <- keeps climbing, issuing meaningless AXI-Lite writes forever
```

**The end marker was detected on exactly the right cycle.** The loop still did not stop, because of this pattern in the testbench:

```verilog
// before (tb_top_kv260.v and its debug copy)
while (1) begin : prog_loop
    ...
    if (e_addr == 4'hE) begin
        $display("[TB] end of CSR program at ptr=0x%04h", ptr);
        disable prog_loop;     // <- this does NOT break out of while(1)!
    end
    ...
end
```

In Verilog, `disable <label>` terminates **only the block that carries the label**. Here `prog_loop` labels the **body of `while(1)`** — one iteration — not the `while` statement. So `disable prog_loop` only ends the current iteration, and `while(1)` immediately starts the next. Even after finding the end marker and printing "end of CSR program", the loop never exits: it **keeps writing the rest of DRAM (mostly zeros) into CSR register 0, then walks past `DRAM_DEPTH` (0x10000) reading X forever and issuing meaningless AXI-Lite writes**. Because the AXI-Lite channel keeps toggling, the state-change stall watchdog could not catch it either; only the 20M-cycle hard timeout stops it, and the PASS/FAIL check is never reached.

**So the actual RTL — `dma.v`, `axi4_master_dram.v`, `axi_lite_csr.v`, `core.v`, `controller.v` — ran all six layers correctly from start to finish.** The bug was purely in the loop-exit code of the newly written testbench.

### Fix

Put the label on a block that **encloses** the `while` statement, so `disable` exits the whole loop:

```verilog
// after
ptr = PROG_BASE;
begin : prog_loop
while (1) begin
    e_addr = ddr_mem[ptr][3:0];
    e_data = ddr_mem[ptr+1];
    ptr = ptr + 2;
    if (e_addr == 4'hE) begin
        $display("[TB] end of CSR program at ptr=0x%04h", ptr);
        disable prog_loop;   // now exits the whole while(1)
    end else if (e_addr == 4'hF) begin
        ...
    end else begin
        ...
    end
end
end
```

**File:** `sim/tb_top_kv260.v`

### Verification — final PASS

Full 6-layer replay with the fixed testbench:

```
===== LAYER 1 : start pulse sent, polling done =====
===== LAYER 1 : done =====
===== LAYER 2 : start pulse sent, polling done =====
===== LAYER 2 : done =====
===== LAYER 3 : start pulse sent, polling done =====
===== LAYER 3 : done =====
===== LAYER 4 : start pulse sent, polling done =====
===== LAYER 4 : done =====
===== LAYER 5 : start pulse sent, polling done =====
===== LAYER 5 : done =====
===== LAYER 6 : start pulse sent, polling done =====
===== LAYER 6 : done =====
[TB] end of CSR program at ptr=0x0000eafa
>>> PASS : top_kv260 (AXI-Lite CSR + AXI4 DDR) bit-exact (928 words)
```

**928/928 PASS.** On the end marker `disable` now exits `while(1)`, the testbench moves straight to DDR verification, and all 928 words match `gold.txt` / `gold_addr.txt`. `top_kv260.v` — AXI-Lite CSR + AXI4 DDR + `core.v` + `dma.v`, the full board topology — was verified end to end for the first time.

## 8. Debugging note — Icarus stdout buffering trap

Running `vvp` in the background with stdout redirected to a file for a long time, **stdout is fully buffered, so the log file looks frozen for hours while the process is actually progressing**. Killing it (`taskkill /F`) loses the unflushed output entirely.

**Mitigation:** do not rely on console output. The testbench itself writes progress (`cyc`, layer number) to a small heartbeat file with `$fopen` / `$fdisplay` / `$fclose` — a separate file handle, independent of the stdout pipe, so it can be watched in real time. Use this pattern for any long background simulation.

---

## Files

| file | status |
|------|------|
| `rtl/dma.v` | fixed (S_IDLE guard restored) |
| `rtl/axi_lite_csr.v` | fixed (`done` sticky latch) |
| `sim/tb_axi4_dma.v` | new, PASS |
| `sim/tb_axi_lite_csr.v` | new, PASS |
| `sim/tb_top_kv260.v` | new, fixed (`disable` label placement), **928/928 PASS** |
| `sim/tb_top.v` | unchanged, re-confirmed 928/928 |

## 9. Next step (done since)

At the time of writing, three things were still open: synthesis/implementation had not been run, the design had not been integrated with a real Zynq PS and Vitis software, and the AXI4 slave BFM only approximated DDR latency. All three have since been completed on the KV260 — the full 6-layer network runs on hardware with 928/928 golden words matching. See [`KV260_HW_BRINGUP.md`](KV260_HW_BRINGUP.md).
