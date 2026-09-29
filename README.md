# VGG-style CNN Inference Accelerator on Kria KV260 (Verilog RTL)

**INT8 weight-stationary CNN accelerator for MNIST — running on real Kria KV260 hardware, bit-exact (928/928) against a Python integer model across all 6 layers.**

> ### Status — **Running on hardware**
> | stage | result |
> |---|---|
> | RTL simulation, BRAM-direct (`tb_top`) | 928/928 bit-exact, 260,816 cycles |
> | RTL simulation, full board topology over AXI (`tb_top_kv260`) | 928/928 bit-exact |
> | Synthesis + place & route on **xck26 (KV260)** | timing met, WNS **+1.652 ns** @ 100 MHz |
> | **On-board, KV260 bare-metal** | **928/928 bit-exact, 68.8 ms / image** |

```
=== KV260 CNN accelerator : full 6-layer run ===
PS-PL isolation removed, PL fabric reset released
DDR image loaded: 65536 words @ 0x00000000, readback mismatches = 0
Layer 1 done  (3112 us)
Layer 2 done  (19542 us)
Layer 3 done  (11057 us)
Layer 4 done  (20799 us)
Layer 5 done  (12546 us)
Layer 6 done  (1524 us)
All 6 layers done in 68846 us
>>> PASS: 928/928 golden words match on KV260 hardware
```

---

## 1. Overview

A single **layer engine**: given 10 CSR registers describing one layer plus a DRAM
holding weights, BN constants and input activations, it streams the layer in,
computes `OH x OW x FN` results into an on-chip accumulator, pushes them through
BN -> ReLU -> requant -> maxpool, writes INT8 activations back to DRAM, then pulses
`done`. A whole network is that program replayed six times with different CSR values.

The PE array itself is just a **vector-matrix multiplier**: 8 bytes in, an 8x32
weight tile held in registers, 32 partial sums out. Everything that makes it a
convolution lives in the address generator inside `controller.v`.

### Target network

VGG-style, every conv 3x3 stride 1, pooling only at stage ends.
Trained in NumPy — **99.13% on MNIST** in float.

```
Conv1_1    1 ->  32   3x3 pad1   28x28 -> 28x28   BN ReLU
Conv1_2   32 ->  32   3x3 pad1   28x28 -> 28x28   BN ReLU  Pool2 -> 14x14
Conv2_1   32 ->  64   3x3 pad1   14x14 -> 14x14   BN ReLU
Conv2_2   64 ->  64   3x3 pad1   14x14 -> 14x14   BN ReLU  Pool2 ->  7x7
Conv3     64 -> 128   3x3 pad0    7x7  ->  5x5    BN ReLU  Pool2 ->  2x2
Affine   512 ->  10
```

606 weight tiles, 38,784 DRAM words of weights in total.

---

## 2. System on KV260

```
 Zynq UltraScale+ PS (Cortex-A53, bare-metal)
   |  M_AXI_HPM0_FPD (32b)                        S_AXI_HPC0_FPD
   |        |                                            ^
   |   AXI Interconnect                             AXI SmartConnect
   |        |  AXI4-Lite                                 |  AXI4
   |        v                                            |
   |   +--------------------------- top_kv260 -----------------------------+
   |   |  axi_lite_csr.v  --CSR-->  top.v (core + dma)  --dram-->  axi4_master_dram.v
   |   |  (CSR regs, sticky done)                        (dma word w <-> DDR byte 4*w)
   |   +--------------------------------------------------------------------+
   |
   +-- DDR : 0x0000_0000 - 0x0003_FFFC  accelerator DRAM window (64K words)
             0x1000_0000 -              bare-metal application
```

| item | value |
|---|---|
| CSR base (AXI-Lite) | `0xA000_0000`, reg *i* at `+4*i`; reg 7 = start, reg 15 (`0x3C`) = done (sticky) |
| DMA DDR window | `DDR_BASE = 0x0`, word *w* at byte `4*w` |
| PL clock | `pl_clk0` = 100 MHz |
| Reset | `proc_sys_reset.peripheral_reset` (active-high) → `top_kv260.rst`; `dcm_locked` tied to 1 |

### Resource usage on xck26 (post-placement)

| resource | used | available | util. |
|---|---:|---:|---:|
| CLB LUTs | 37,294 | 117,120 | 31.84% |
| CLB Registers | 25,909 | 234,240 | 11.06% |
| Block RAM Tile | 50 | 144 | 34.72% |
| DSPs | 32 | 1,248 | 2.56% |
| URAM | 0 | 64 | 0% |

Timing met at 100 MHz: **WNS +1.652 ns, WHS +0.012 ns, 0 failing endpoints.**

---

## 3. Architecture

```
top_kv260.v               board top: AXI-Lite CSR slave + AXI4 DDR master around top.v
  +-- axi_lite_csr.v      PS -> CSR bus, sticky done latch for polling
  +-- axi4_master_dram.v  dma.v's word interface -> AXI4 single-beat reads/writes
  +-- top.v               the accelerator proper
        +-- dma.v         one linear burst at a time: mm2s (read), s2mm (write)
        +-- core.v        datapath + control
              +-- controller.v      the only FSM. 20 states, all loop counters
              +-- input_buffer.v    ibuf : NB_IN=2 banks x 32b x 32, ping-pong
              +-- weight_buffer.v   wbuf : NB_W=8 banks x 32b x 32, ping-pong
              +-- bank_unpack.v     x2 : bank words -> flat INT8 byte lanes
              +-- pe_array_hier.v   8 rows x 32 cols, weight-stationary
              |     +-- pe_adder_tree.v -> pe_col.v -> PE.v -> multiplier.v
              |                        \-> adder_tree.v -> rca.v -> full_adder.v
              +-- accumulator.v     32 lanes x 24b x 1024 slots, 1 BRAM per lane
              +-- bn_regfile.v      384 channels of (A,B) as 12 groups of 32
              +-- batch_norm.v      (acc * A >> s1) + B
              +-- ReLU.v
              +-- requant.v         (x * M2) >> s2, saturate to INT8
              +-- maxpool.v         2x2 stride 2, line buffer in distributed RAM
              +-- output_buffer.v   obuf : NB_OUT=8 banks x 32b x 64, ping-pong

sim/tester.v              simulation model of the PS: owns a BRAM "DRAM" and
                          replays the CSR program stored in it (used by tb_top)
```

Design details — dataflow, row streaming, fused maxpool, gate-level Baugh-Wooley
multiplier, bit widths, memory layouts, BRAM latency discipline — are in
[`docs/DATAFLOW.md`](docs/DATAFLOW.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
and [`docs/DESIGN_NOTES.md`](docs/DESIGN_NOTES.md).

### Dataflow

```
for ft:                              output-channel tile  (COL_SIZE = 32 at a time)
  for ct:                            input-channel tile   (ROW_SIZE = 8 at a time)
    for fh:
      for fw:
        load W tile (ft,ct,fh,fw)    64 DRAM words
        PUSH -> PE                   ROW_SIZE+1 cycles
        for oh:                      output row
          load input row (oh+fh-pad) of group ct    W*NB_IN words, prefetched
          for ow:                    output column
            ST_PIX_RD  ibuf address out, accumulator READ
            ST_PIX_WR  ibuf data in,     accumulator WRITE
  drain: acc -> BN -> ReLU -> requant -> maxpool -> obuf -> s2mm
```

Key points:
- **PE array 8x32** chosen by a synthesis sweep (32x32 = 180% LUT on XC7Z020, 8x32 = 61%).
- **Row streaming**: only one input row per channel group is live, so ibuf depth = W (28)
  instead of 3,136 rows. ibuf ping-pong is load-bearing, not an optimisation.
- **Maxpool fused** into the drain after requant (monotonic, bit-identical, 8-bit compare).
- **No `*` operator** in the MAC datapath: Baugh-Wooley signed multiplier + hand-written RCA.

---

## 4. Verification

### 4.1 Simulation

| testbench | what it checks | result |
|---|---|---|
| `tb_top` | full 6-layer network, `tester.v` + BRAM DRAM, vs `quant_cnn.py` | **928/928**, 260,816 cycles |
| `tb_top_kv260` | full board topology: AXI-Lite CSR driven like PS software + AXI4 DDR slave BFM with random latency | **928/928** |
| `tb_axi4_dma` | `dma.v` + `axi4_master_dram.v` vs random-latency AXI4 slave, independent AW/W ordering | PASS, 708 words over 50 rounds |
| `tb_axi_lite_csr` | 200 randomised AXI-Lite writes, back-pressure, done-register readback | PASS |
| `tb_accumulator`, `tb_maxpool`, `tb_controller`, ... | module level | PASS |

Every testbench is **mutation-tested** — the DUT is deliberately broken and the test
must fail. A test that has never failed has not been shown to test anything.

### 4.2 On hardware

`sw/kv260_test` loads the DRAM image (input + weights + BN + CSR program) into DDR,
replays the CSR program exactly like `tb_top_kv260`, and compares the 928 output words
against the golden model. **928/928 match.**

| layer | on board | BRAM-direct sim (ideal memory) |
|---|---:|---:|
| Conv1_1 | 3.11 ms | 0.12 ms |
| Conv1_2 | 19.54 ms | 0.68 ms |
| Conv2_1 | 11.06 ms | 0.43 ms |
| Conv2_2 | 20.80 ms | 0.80 ms |
| Conv3 | 12.55 ms | 0.53 ms |
| Affine | 1.52 ms | 0.06 ms |
| **total** | **68.8 ms** | **2.61 ms** |

**Every layer is memory-bound.** `axi4_master_dram.v` issues single-beat AXI4
transactions, so each DDR word pays a full round trip to the PS DDR controller.
The same datapath with ideal single-cycle memory takes 2.61 ms — **AXI4 burst
transfers are the next step** and the largest available speed-up.

---

## 5. Bring-up story

Getting from "passes in simulation" to "passes on the board" surfaced bugs that no
simulation had exercised. Full write-ups with evidence:

| document | covers |
|---|---|
| [`docs/DMA_AXI_FIX.md`](docs/DMA_AXI_FIX.md) | `dma.v` S_IDLE re-trigger race after the AXI rewrite (918/928 → 928/928); `axi_lite_csr` done pulse unobservable by polling (→ sticky latch); a testbench `disable`-label bug that masked a clean run |
| [`docs/KV260_HW_BRINGUP.md`](docs/KV260_HW_BRINGUP.md) | 7 board-level problems: UART MIO not routed, stale Vitis platform, reset polarity, unconnected `dcm_locked`, FSBL link failure, and the root cause of the CPU hang |

Root cause of the board hang, in one line: **in a JTAG-only flow the FSBL never
removes PS-PL isolation or releases `pl_resetn0`** — it only does that when it loads
a PL partition from a boot image. Every AXI access to the PL therefore went
unanswered (the A53 could not even be halted). Found by single-stepping to the
write that stalls (write buffer full after 5 posted writes = no BRESP ever), then
confirming with direct JTAG DAP access that bypasses the CPU, then reading PS
registers (`GPIO DATA_5` bit 31 = `pl_resetn0` still asserted). Fixed in the
application by replaying `psu_ps_pl_isolation_removal` / `psu_ps_pl_reset_config`
from `psu_init`.

---

## 6. Repository layout

```
rtl/                synthesizable Verilog (26 modules + top_kv260, AXI adapters)
rtl/ip/             blk_mem_gen .xci for ibuf / wbuf / obuf / accumulator
sim/                testbenches + tester.v (PS model); sim/ip/dram.xci
python/             quant_cnn.py (quantiser + golden model), quant.json,
                    dram.txt / gold.txt / gold_addr.txt (generated), debug tools
constraints/        clk.xdc (100 MHz)
vivado/bd/          KV260 block design (CNN_KV260.bd) + its IP configs
vivado/ip_repo/     top_kv260 packaged as a Vivado IP
sw/kv260_test/      bare-metal test app: main.c, lscript.ld, gen_headers.sh
docs/               ARCHITECTURE / DATAFLOW / DESIGN_NOTES / DMA_AXI_FIX / KV260_HW_BRINGUP
```

## 7. Reproducing

**Simulation** — add `rtl/`, `rtl/ip/`, `sim/`, `sim/ip/` to a Vivado project (or
compile with Icarus using the `blk_mem_gen` behavioural models), put
`python/dram.txt`, `gold.txt`, `gold_addr.txt` in the simulation working directory,
run `tb_top` or `tb_top_kv260`.

**Hardware** (Vivado / Vitis 2022.1, KV260):
1. Add `vivado/ip_repo` as an IP repository, open/recreate `vivado/bd/CNN_KV260.bd`,
   generate the HDL wrapper, generate bitstream, export hardware (XSA incl. bitstream).
2. In Vitis create a platform from the XSA (standalone, `psu_cortexa53_0`) and an empty
   application; copy `sw/kv260_test/src/*` into it.
3. Run `sw/kv260_test/gen_headers.sh` to produce `dram_img.h` and `gold.h`.
4. Build, run over JTAG, watch the UART (115200 8N1).

`python/quant_cnn.py` regenerates `dram.txt` / `gold*.txt` from the trained
parameters (`params_hw.pkl`, not included) via `--t2 <dir>`.

---

## 8. Tools

| | |
|---|---|
| HDL | Verilog-2001 |
| Board | AMD/Xilinx Kria **KV260** (xck26-sfvc784-2LV-c) |
| FPGA tools | Vivado 2022.1, Vitis 2022.1 |
| Simulation | Vivado xsim, Icarus Verilog |
| Golden model / quantiser | Python 3 + NumPy |

## 9. Known limitations

- **Memory-bound on hardware** (single-beat AXI4) — see §4.2. Burst transfers are next.
- **JTAG bring-up only.** Standalone SD boot (BOOT.BIN) not yet done; there the FSBL
  handles isolation/reset itself and the application's manual release becomes redundant.
- **Conv1_1 low-channel problem** — `C=1` wastes PE rows; space-to-depth would help more
  than raising PE utilisation. Small-P layers (Conv3, Affine) pay per-tile overhead.
  Affine prefers the opposite array shape (3.8x). See `docs/DESIGN_NOTES.md`.
