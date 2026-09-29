# KV260 Hardware Bring-up Log

**Dates:** 2026-09-22 – 2026-09-29
**Goal:** take the CNN accelerator RTL (`top_kv260.v`), already verified 928/928 in simulation, onto a real Kria KV260 and prove the whole system works in hardware: the PS (Arm Cortex-A53) drives the CSRs over AXI-Lite, and the accelerator reads/writes DDR over AXI4.

**Result:** all 6 layers run on the board and **928/928 output words match the golden model** — bit-identical to simulation. 68.8 ms per image.

**Scope:** none of the problems below were bugs in the RTL datapath (`dma.v`, `axi_lite_csr.v`, `axi4_master_dram.v`, `core.v`, `controller.v`); that logic had already been verified 928/928 in simulation (see [`DMA_AXI_FIX.md`](DMA_AXI_FIX.md)). Every issue here was at the level of **(1) the Vivado block design (board wiring), (2) the Vitis platform / build toolchain, or (3) the JTAG boot flow**.

---

## Contents

1. IP packaging and block design
2. Problem 1 — no UART output at all (MIO not routed)
3. Problem 2 — Vitis platform keeps using a stale XSA
4. Problem 3 — reset polarity: `top_kv260_0` held in reset
5. Problem 4 — `dcm_locked` unconnected, reset never released
6. Problem 5 — one wire deletion disconnected five reset pins
7. Problem 6 — FSBL link failure (duplicate symbols from `psu_init_gpl.c`)
8. Problem 7 — CPU hangs on the first CSR write (AXI bus-level hang)
9. Problem 7 resolved — root cause: PS-PL isolation and fabric reset never released
10. Final result — full 6-layer run on hardware, 928/928
11. Debugging methodology
12. Status and remaining work

---

## 1. IP packaging and block design

`top_kv260.v` (board-level wrapper around `axi_lite_csr.v` + `axi4_master_dram.v` + `top.v`) was packaged with **Tools → Create and Package New IP** so it can be dropped into Vivado IP Integrator.

- IP repository kept in a separate `ip_repo/top_kv260_v1` folder, away from the `.xpr` and generated project directories.
- Vivado recognised the `s_axi_*` / `m_axi_*` naming convention and grouped the ports into interfaces automatically.
- `m_axi` has burst signals (`AWLEN/AWSIZE/AWBURST/WLAST`), so it was classified as full AXI4; `s_axi` has none, so it became AXI4-Lite — Vivado infers the protocol purely from the port list.
- Address block `reg0` on `s_axi` defaulted to a 4 KB range (`0x1000`) while `axi_lite_csr.v` decodes only `ADDR_WIDTH=6` (64 bytes). The rest is reserved but unused — **functionally harmless**, left as is.

Block design:
- Zynq UltraScale+ MPSoC PS + `top_kv260_0` + `axi_smc` (SmartConnect, DDR path) + `ps8_0_axi_periph` (AXI Interconnect, CSR path) + `rst_ps8_0_96M` (Processor System Reset)
- `top_kv260_0.s_axi` → `ps8_0_axi_periph` → PS `M_AXI_HPM0_FPD` (CSR control)
- `top_kv260_0.m_axi` → `axi_smc` → PS `S_AXI_HPC0_FPD` (DDR access)

---

## 2. Problem 1 — no UART output at all

### Symptom
The FSBL ran (the JTAG download log reported success) but nothing printed with `xil_printf` ever reached the serial terminal, on either COM6 or COM7.

### Diagnosis
Device Manager showed `USB Serial Converter A/B/C/D` (the FTDI quad chip) and `USB Serial Port (COM6/COM7)` correctly — so not a cable or driver problem.

In the PS block, **I/O Configuration → UART: neither UART0 nor UART1 was enabled.** On Zynq UltraScale+, peripherals such as UART reach physical pins through the **MIO (Multiplexed I/O)** crossbar and must be assigned explicitly in the hardware design. With UART disabled, the PS never drove the UART pins at all.

### Root cause
The Vivado project was created from the **bare part number (xck26…) instead of the KV260 board preset**. With the board file, Vivado knows that UART1 is wired to MIO 36/37 and enables it automatically; with a bare part, nothing is configured for you.

### Fix
- PS Re-customize IP → I/O Configuration → UART → enable **UART 1**
- Pins: **MIO 36 .. 37** (standard UART1 routing on the Kria K26 SOM)
- No Board tab was available (no board preset), so the MIO pair had to be chosen by hand. MIO pairs come only in fixed groups (0-1, 4-5, 8-9 … 36-37).

### Verification
After regenerating the bitstream and refreshing the Vitis platform, the BSP (`system.mss`) picked up `stdin`/`stdout = psu_uart_1`, and the terminal showed `Xilinx Zynq MP First Stage Boot Loader` and the application banner.

---

## 3. Problem 2 — Vitis platform keeps using a stale XSA

### Symptom
After fixing UART in Vivado → Generate Bitstream → Export Hardware, repeated **Clean → Build** of the platform in Vitis still produced a BSP (`xparameters.h`) with **no UART entries at all**, and the UART stayed silent.

### Diagnosis
Stopped trusting the GUI and **compared file timestamps and md5 checksums directly**:

```bash
# XSA exported by Vivado
ls -la --time-style=full-iso <vivado_proj>/CNN_KV260_wrapper.xsa
# XSA the Vitis platform actually uses
ls -la --time-style=full-iso <vitis_ws>/CNN_KV260/hw/CNN_KV260_wrapper.xsa
# bitstream actually programmed at launch
ls -la --time-style=full-iso <vitis_ws>/kv260_test/_ide/bitstream/CNN_KV260_wrapper.bit
md5sum <the files above>
```

The Vivado export was current, but the XSA inside the platform's `hw/` folder was **hours old**. Clean/Build on the platform does not reliably re-import the XSA (Vitis 2022.1 behaviour). A first attempt replaced the copy under `export/…/hw/` — which is the platform's *build output*, not its source — so it had no effect; the real source is the platform's top-level `hw/` folder.

### Fix
Bypass the GUI and **overwrite the platform's source XSA and the files extracted from it**:

```bash
HW="<vitis_ws>/CNN_KV260/hw"
NEW="<vivado_proj>/CNN_KV260_wrapper.xsa"
cp "$HW"/CNN_KV260_wrapper.xsa "$HW/_bak_<date>/"   # backup
unzip -o "$NEW" -d /tmp/extracted                    # the XSA also carries psu_init.c etc.
cp "$NEW" "$HW/CNN_KV260_wrapper.xsa"
cp /tmp/extracted/psu_init.c /tmp/extracted/psu_init.h /tmp/extracted/psu_init.tcl "$HW/"
```

Then Refresh (F5) → Clean → Build. Where even that was not enough, the platform was deleted and recreated directly from the new XSA. From then on, every bitstream change went through an **md5 checklist of bitstream / XSA / FSBL / staged bitstream** before anything was run on the board.

### Lesson
Do not trust "Clean/Build" alone — verify the actual files on disk by timestamp and checksum.

---

## 4. Problem 3 — reset polarity: `top_kv260_0` held in reset

### Symptom
With UART working, the program printed its banner and then stopped at the first CSR write (`REG(0) = ...`); `Layer 1 config written...` never appeared.

### Diagnosis
`top_kv260.v`:

```verilog
// top_kv260.v, line 11
input                        rst,              // active HIGH (from PS FCLK_RESET0_N, inverted)
...
// lines 71-75
// NOTE: s_axi_aresetn is active LOW (AXI convention), rst here is active
// HIGH (matches core.v/dma.v). Board-level reset wiring must invert once;
// this module inverts it right here so both sub-blocks see the polarity
// they each expect.
wire s_axi_aresetn = ~rst;
```

`rst` is **active-high**. Querying the actual wiring in the Vivado Tcl console:

```tcl
get_bd_pins -of_objects [get_bd_nets -of_objects [get_bd_pins top_kv260_0/rst]]
```

showed it tied to `peripheral_aresetn` — the **active-low** output of Processor System Reset. In normal operation `peripheral_aresetn = 1`, which `top_kv260` reads as "in reset": a classic inverted-polarity bug.

### Fix
Processor System Reset also provides an **active-high `peripheral_reset`** output:

```
rst_ps8_0_96M.peripheral_reset[0:0]  →  top_kv260_0.rst
```

### Verification
```tcl
get_bd_pins -of_objects [get_bd_nets -of_objects [get_bd_pins top_kv260_0/rst]]
→ /rst_ps8_0_96M/peripheral_reset /top_kv260_0/rst
```

---

## 5. Problem 4 — `dcm_locked` unconnected, reset never released

### Symptom
After the polarity fix the **symptom was unchanged**, even with bitstream and XSA verified by md5.

### Diagnosis
Checking every input of `rst_ps8_0_96M` found **`dcm_locked` with no connection at all** in the hardware handoff:

```
<PORT DIR="I" NAME="dcm_locked" SIGIS="undef"/>   <!-- no CONNECTIONS -->
```

`proc_sys_reset` holds its reset outputs until `dcm_locked` goes high. Left unconnected, Vivado ties it to 0. This design uses the PS clock directly with no MMCM/PLL, so nothing would ever raise it.

### Fix
Add a **Constant** (`xlconstant`) IP, width 1, value 1, and connect it — the standard approach when there is no clock-generation IP:

```
xlconstant_0.dout[0:0]  →  rst_ps8_0_96M.dcm_locked
```

### Verification
```tcl
get_bd_pins -of_objects [get_bd_nets -of_objects [get_bd_pins rst_ps8_0_96M/dcm_locked]]
→ /xlconstant_0/dout /rst_ps8_0_96M/dcm_locked
```

---

## 6. Problem 5 — one wire deletion disconnected five reset pins

### What happened
While fixing Problem 3, the old `peripheral_aresetn` wire to `top_kv260_0.rst` was deleted on the canvas. In IP Integrator, when one net fans out to several pins, clicking the trunk and deleting removes **the whole net**, not just one branch.

### Detection
Validate Design (F6):

```
[BD 41-759] The input pins (listed below) are either not connected or do not have a source port...
/ps8_0_axi_periph/ARESETN
/ps8_0_axi_periph/S00_ARESETN
/ps8_0_axi_periph/M00_ARESETN
/ps8_0_axi_periph/S01_ARESETN
```

`axi_smc.aresetn` was also cut.

### Fix
Reconnect all five pins to `rst_ps8_0_96M.peripheral_aresetn[0:0]` (these AXI infrastructure IPs correctly expect active-low reset), then confirm with Tcl that all five sit on one net.

### Lesson
To remove one branch of a fanned-out net, select exactly that pin-to-pin segment. Always re-run Validate Design after rewiring.

---

## 7. Problem 6 — FSBL link failure (duplicate symbols from `psu_init_gpl.c`)

### What happened
While working around Problem 2, `psu_init_gpl.c`/`.h` were copied into the platform's `zynqmp_fsbl/` folder along with `psu_init.c`/`.h`/`.tcl`.

### Symptom
```
make: *** [Makefile:27: fsbl_a53.elf] Error 1
...multiple definition of `psu_pll_init_data'; psu_init.o (symbol from plugin):(.text+0x0): first defined here
...multiple definition of `psu_init'; ...
```
Every object compiled, but the **final link failed** and `fsbl_a53.elf` was never produced.

### Cause
`psu_init.c` and `psu_init_gpl.c` are alternative copies of the same code under different licences — only one belongs in a project. The Vitis build compiles every `.c` in the folder, so both were linked and every symbol was defined twice. A self-inflicted mistake.

### Fix
```bash
rm zynqmp_fsbl/psu_init_gpl.c zynqmp_fsbl/psu_init_gpl.h zynqmp_fsbl/psu_init_gpl.o zynqmp_fsbl/psu_init_gpl.d
```
The GUI only reported "Error 1"; the real cause came from reading the build log file (`.log/CNN_KV260_.build.ui.log`) directly.

---

## 8. Problem 7 — CPU hangs on the first CSR write

### Symptom
After Problems 3–6 were fixed, the program **still stopped at the first CSR write** — the symptom never changed from start to finish.

### What the debugger showed
Suspend in the Debug view, and `stop` in XSCT, both failed:
```
Cannot suspend: TCF error report:
Error text: Cannot halt processor core, timeout
```
A software infinite loop can always be halted. A core that cannot be halted is **stuck inside a bus transaction that never completes** — an AXI response that never comes back.

### Hypotheses tested and rejected

| hypothesis | test | result |
|---|---|---|
| `s_axi` accidentally disconnected | `get_bd_intf_pins -of_objects [get_bd_intf_nets -of_objects [get_bd_intf_pins top_kv260_0/s_axi]]` | connected to `ps8_0_axi_periph/M00_AXI` — rejected. (A first query with `get_bd_nets` on individual signals returned nothing and looked like a disconnect; `s_axi` is a **bus interface pin**, whose individual signals have no nets of their own. `get_bd_intf_*` is required — false alarm.) |
| timing violation | post-route Timing Summary | WNS +2.052 ns, WHS +0.014 ns, 0 failing endpoints — rejected |
| AXI width converter (`M_AXI_HPM0_FPD` 128-bit → 32-bit AXI-Lite via `auto_ds`, with recurring `AWUSER_WIDTH` mismatch warnings) | set HPM0 FPD data width to 32 bits, rebuilt | identical symptom — rejected |
| PS-PL isolation | ran `psu_ps_pl_isolation_removal` / `psu_ps_pl_reset_config` from `psu_init.tcl` in XSCT | no change — **but this test was invalid**: it was run after the CPU had already hung, and an in-flight stalled transaction cannot be recovered. Revisited in §9. |

---

## 9. Problem 7 resolved — PS-PL isolation and fabric reset never released

### Clue 1: breakpoint + single-step
Asynchronous Suspend fails once the core is stuck, so a **breakpoint was placed on `REG(0)` beforehand** and the code single-stepped with F6. `REG(0)`–`REG(4)` stepped through; **`REG(5)` hung**.

The A53 maps the PL address range as Device-nGnRE (posted writes allowed): writes go into the write buffer and the core continues until the buffer fills. **So no BRESP had ever come back** — the first four writes were only hidden by buffering.

### Clue 2: bypass the CPU with direct JTAG DAP access
After `loadhw` in XSCT:
```
mwr 0xa0000000 0x12345678  → AP transaction timeout
mrd 0xa0000000             → AXI AP transaction error, DAP status 0x30000021
```
**CPU, MMU and software ruled out: the PL does not answer AXI at all.**
(After this error the DAP's sticky error bits locked every target with `Cannot open JTAG port`; only a board power cycle recovered it.)

### PS registers checked (XSCT `mrd`, no rebuild needed)

| register | address | value | meaning |
|---|---|---|---|
| GPIO `DATA_5` | `0xFF0A0054` | `0x00000000` | **bit 31 = 0 → `pl_resetn0` (EMIO GPIO[95]) asserted** |
| `REQ_PWRUP_STATUS` | `0xFFD80110` | `0x00000000` | no PL power-up request pending |
| `PL0_REF_CTRL` | `0xFF5E00C0` | `0x01010A00` | CLKACT = 1, 100 MHz — clock is running |

Clock wiring was also re-verified with Tcl: `pl_clk0` drives `maxihpm0_fpd_aclk`, `saxihpc0_fpd_aclk`, the IP clock, the interconnect and the SmartConnect.

### Clue 3: a manual XSCT init sequence works
```tcl
rst -system
source psu_init.tcl
psu_init
psu_ps_pl_isolation_removal      ;# the Vitis debug launch never does this
fpga -file CNN_KV260_wrapper.bit
psu_ps_pl_reset_config           ;# nor this
mwr 0xa0000000 0x00060001  ...   ;# 9 layer-config registers
mwr 0xa000001c 1                 ;# start
mrd 0xa000003c                   → 00000001   (done)
```
**The accelerator completed Layer 1 on real hardware for the first time.** This exercised both the AXI-Lite CSR path and the AXI4 DMA path (`done` cannot assert without the DMA completing its DDR reads and writes).

### Root cause
In `psu_init.c`, `psu_ps_pl_isolation_removal_data()` and `psu_ps_pl_reset_config_data()` are **called only from `xfsbl_partition_load.c` / `xfsbl_handoff.c`** — i.e. only when the FSBL loads a PL partition out of a boot image (BOOT.BIN). The Vitis JTAG debug launch programs the bitstream with XSCT `fpga -file`, outside the FSBL, and then downloads the ELF. That path never runs these functions, so PS-PL isolation stays up and `pl_resetn0` stays asserted, and the PL never answers.

The reset-polarity (Problem 3) and `dcm_locked` (Problem 4) bugs were real, but this higher-level cause masked the effect of fixing them.

### Fix (application code, no bitstream rebuild)
The application performs the two steps the FSBL skipped, at the top of `main()`:

```c
static int remove_ps_pl_isolation(void)
{
    int guard = 100000;
    Xil_Out32(0xFFD80118U, (Xil_In32(0xFFD80118U) & ~0x00800000U) | 0x00800000U); // REQ_PWRUP_INT_EN.PL
    Xil_Out32(0xFFD80120U, (Xil_In32(0xFFD80120U) & ~0x00800000U) | 0x00800000U); // REQ_PWRUP_TRIG.PL
    while (((Xil_In32(0xFFD80110U) & 0x00800000U) != 0U) && (--guard > 0)) {       // pending until 0
        ;
    }
    return (guard > 0);
}

static void release_pl_fabric_reset(void)   // pl_resetn0 = EMIO GPIO[95] = bank 5 bit 31
{
    Xil_Out32(0xFF0A002CU, (Xil_In32(0xFF0A002CU) & ~0xFFFF0000U) | 0x80000000U); // MASK_DATA_5_MSW
    Xil_Out32(0xFF0A0344U, 0x80000000U);   // DIRM_5
    Xil_Out32(0xFF0A0348U, 0x80000000U);   // OEN_5
    Xil_Out32(0xFF0A0054U, 0x80000000U);   usleep(1000);
    Xil_Out32(0xFF0A0054U, 0x00000000U);   usleep(1000);
    Xil_Out32(0xFF0A0054U, 0x80000000U);   usleep(1000);
}
```

Every address and value comes from the `psu_init.tcl` shipped inside the XSA — nothing guessed.

> Two slips on the way: the poll condition was first written as `== 0U` (the original `mask_pollOnValue(..., 0x00000000)` waits until the bit *reads 0*); and the app's `_ide/psinit/psu_init.tcl` was a stale copy from older hardware and was replaced with the current one.

### Verification — board output
```
=== KV260 CNN accelerator test ===
PS-PL isolation removed (PWRUP_STATUS = 0x00000000)
PL fabric reset released (GPIO DATA_5 = 0x80000000)
Layer 1 config written. Starting...
>>> PASS: Layer 1 done detected.
```
**CSR control and a complete Layer 1 run from the Vitis application alone, no manual XSCT steps.**

### Side notes
- Right after power-on the UART shows `pxelinux.cfg` and `ethernet@ff0e0000 Waiting for PHY auto negotiation`: the KV260's factory U-Boot in QSPI trying to network-boot. Unrelated; the Vitis launch resets the system and replaces it.
- After hours with Vivado, Vitis and XSCT open together, Vivado raised an Internal Exception ("insufficient system resources"). Not design-related — the PC ran out of resources; closing Vivado resolved it.

---

## 10. Final result — full 6-layer run on hardware, 928/928

### Move the application out of the DMA window
`axi4_master_dram.v` uses `DDR_BASE = 0x0000_0000` (DMA word `w` ↔ DDR byte `4*w`), so the DMA owns DDR `0x0 – 0x3FFFC`. The default linker script also loads the application at `0x0`, so loading the DRAM image would overwrite the running program. `lscript.ld` now places `psu_ddr_0_MEM_0` at `0x1000_0000` (no bitstream change).

### Test program (`sw/kv260_test/src/main.c`)
1. Remove PS-PL isolation and release the fabric reset (§9).
2. `Xil_DCacheDisable()` — the DMA reads and writes DDR behind the CPU's back, so all CPU accesses are uncached.
3. Copy the DRAM image (`dram.txt`: input image + weights + BN parameters + CSR program, 65,536 words, embedded as `dram_img.h`) into DDR at `0x0` and read it all back to verify.
4. Replay the CSR program at `PROG_BASE (0xEA80)` with the same rules as `tester.v` / `tb_top_kv260.v` (`0xF` = start + poll done, `0xE` = end), timing each layer with `XTime`.
5. Compare the 928 output words with the golden model (`gold.h`).

The data files are the same ones used for the 928/928 simulation run (identical md5).

### Board output (2026-09-29)
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

**RTL simulation (928/928) and hardware (928/928) agree bit for bit.**

### Per-layer time (PL at 100 MHz)

| layer | on board | sim, AXI BFM (0–5 cycle latency)\* | sim, BRAM-direct (1-cycle memory) |
|---|---:|---:|---:|
| Conv1_1 | 3.11 ms | ~1.2 ms | 0.12 ms |
| Conv1_2 | 19.54 ms | ~5.5 ms | 0.68 ms |
| Conv2_1 | 11.06 ms | ~3.4 ms | 0.43 ms |
| Conv2_2 | 20.80 ms | ~6.0 ms | 0.80 ms |
| Conv3 | 12.55 ms | ~3.7 ms | 0.53 ms |
| Affine | 1.52 ms | ~0.35 ms | 0.06 ms |
| **total** | **68.8 ms** | **~20 ms** | **2.61 ms** |

\* estimated from `tb_top_kv260.v` cumulative cycle counts at layer boundaries.

**Interpretation:** the board uses real DDR4 through the PS DDR controller. `axi4_master_dram.v` issues **single-beat (burst length 1)** transactions, so every word pays a full round trip — far longer on real DDR than the BFM's 0–5 cycles. The arithmetic is exact but the design is memory-bound; **AXI4 burst transfers (AWLEN/ARLEN > 0) are the biggest available speed-up.**

---

## 11. Debugging methodology

1. **Verify files, not GUI state.** Vitis Clean/Build repeatedly failed to pick up new hardware, so every step was confirmed with `ls --time-style=full-iso` timestamps and `md5sum`.
2. **Cross-check RTL comments against the real wiring.** The `// active HIGH` comment in `top_kv260.v`, checked against the block design in Tcl, exposed the reset-polarity bug.
3. **Query connectivity in Tcl instead of reading the diagram.** Overlapping wires mislead; `get_bd_pins` / `get_bd_nets` / `get_bd_intf_pins` / `get_bd_intf_nets` give exact answers — but bus interface pins must be queried with the `get_bd_intf_*` family.
4. **Treat debugger failures as data.** "Cannot halt processor core" meant a bus-level hang, not a software loop. When asynchronous halt was impossible, a breakpoint placed *before* the fault plus single-stepping located the exact stalling write.
5. **Bypass layers to isolate the fault.** Direct JTAG DAP access removed the CPU, MMU and software from the picture in one step, and reading PS registers found the asserted `pl_resetn0`.
6. **Exhaust free checks before expensive ones.** Tcl queries, timing reports and register reads cost nothing; a bitstream rebuild costs tens of minutes, so it was spent only on hypotheses that survived the free checks.

---

## 12. Status and remaining work

- [x] IP packaging and block design
- [x] UART routed (MIO 36/37)
- [x] Workaround for stale Vitis platform (direct file verification / replacement)
- [x] Reset polarity fixed (`peripheral_reset`)
- [x] `dcm_locked` tied high (`xlconstant`)
- [x] Reset nets restored after accidental net deletion
- [x] FSBL link fixed (`psu_init_gpl.c` removed)
- [x] CPU hang on first CSR write — **root cause: PS-PL isolation and fabric reset not released in the JTAG flow; fixed in the application**
- [x] Layer 1 completes on hardware
- [x] Application moved to `0x1000_0000`
- [x] DRAM image loaded into DDR and verified (65,536 words, 0 mismatches)
- [x] **Full 6-layer run on hardware, 928/928 golden words match** (68.8 ms)
- [ ] (performance) AXI4 burst transfers in `axi4_master_dram.v` / `dma.v`
- [ ] (deployment) SD boot from BOOT.BIN — the FSBL then handles isolation/reset itself; check the application's manual release is harmless there
