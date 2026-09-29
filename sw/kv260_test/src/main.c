#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xtime_l.h"
#include "sleep.h"
#include "dram_img.h"   /* DRAM_WORDS, dram_img[] : input image + weights + BN + CSR program */
#include "gold.h"       /* GOLD_N, gold_addr[], gold_val[] : expected 6-layer output words */

#define CSR_BASE   0xA0000000UL   /* axi_lite_csr, Vivado Address Editor */
#define DDR_BASE   0x00000000UL   /* axi4_master_dram DDR_BASE: dma word w <-> byte DDR_BASE + 4*w */
#define PROG_BASE  0xEA80U        /* CSR program location inside dram_img (quant_cnn.py) */
#define CSR_START  7U
#define CSR_DONE   15U
#define DONE_GUARD 200000000U

static inline void csr_wr(u32 idx, u32 v) { Xil_Out32(CSR_BASE + ((UINTPTR)idx << 2), v); }
static inline u32  csr_rd(u32 idx)        { return Xil_In32(CSR_BASE + ((UINTPTR)idx << 2)); }
static inline void ddr_wr(u32 w, u32 v)   { Xil_Out32(DDR_BASE + ((UINTPTR)w << 2), v); }
static inline u32  ddr_rd(u32 w)          { return Xil_In32(DDR_BASE + ((UINTPTR)w << 2)); }

static u32 elapsed_us(XTime t0, XTime t1)
{
    return (u32)(((t1 - t0) * 1000000ULL) / COUNTS_PER_SECOND);
}

// PS-PL isolation is torn down by FSBL only on the boot-image PL-partition
// path, so a JTAG-only bring-up leaves the PL walled off and every AXI access
// times out. Same registers as psu_ps_pl_isolation_removal_data() in psu_init.c.
static int remove_ps_pl_isolation(void)
{
    int guard = 100000;
    Xil_Out32(0xFFD80118U, (Xil_In32(0xFFD80118U) & ~0x00800000U) | 0x00800000U); // REQ_PWRUP_INT_EN.PL
    Xil_Out32(0xFFD80120U, (Xil_In32(0xFFD80120U) & ~0x00800000U) | 0x00800000U); // REQ_PWRUP_TRIG.PL
    while (((Xil_In32(0xFFD80110U) & 0x00800000U) != 0U) && (--guard > 0)) {       // REQ_PWRUP_STATUS.PL: pending until 0
        ;
    }
    return (guard > 0);
}

// FSBL only releases pl_resetn0 when it loads a PL partition out of a boot
// image. Same register sequence as psu_ps_pl_reset_config_data() in psu_init.c:
// pl_resetn0 is EMIO GPIO[95] = bank 5 bit 31.
static void release_pl_fabric_reset(void)
{
    Xil_Out32(0xFF0A002CU, (Xil_In32(0xFF0A002CU) & ~0xFFFF0000U) | 0x80000000U); // MASK_DATA_5_MSW
    Xil_Out32(0xFF0A0344U, 0x80000000U);   // DIRM_5 : drive as output
    Xil_Out32(0xFF0A0348U, 0x80000000U);   // OEN_5  : output enable
    Xil_Out32(0xFF0A0054U, 0x80000000U);   // DATA_5 : deassert
    usleep(1000);
    Xil_Out32(0xFF0A0054U, 0x00000000U);   // assert
    usleep(1000);
    Xil_Out32(0xFF0A0054U, 0x80000000U);   // deassert
    usleep(1000);
}

int main()
{
    XTime t0, t1, t_all0, t_all1;
    u32 w, i, errors = 0, bad_load = 0;
    u32 ptr = PROG_BASE;
    int layer = 0;

    xil_printf("\r\n=== KV260 CNN accelerator : full 6-layer run ===\r\n");

    if (!remove_ps_pl_isolation()) {
        xil_printf(">>> WARNING: PS-PL power-up request timed out\r\n");
    }
    release_pl_fabric_reset();
    xil_printf("PS-PL isolation removed, PL fabric reset released\r\n");

    // DMA masters DDR behind the A53's back; keep every CPU access uncached so
    // neither side ever sees stale lines.
    Xil_DCacheDisable();

    // ---- load DRAM image into the accelerator's DDR window ----
    for (w = 0; w < DRAM_WORDS; w++) {
        ddr_wr(w, dram_img[w]);
    }
    for (w = 0; w < DRAM_WORDS; w++) {
        if (ddr_rd(w) != dram_img[w]) {
            bad_load++;
        }
    }
    xil_printf("DDR image loaded: %d words @ 0x%08x, readback mismatches = %d\r\n",
               (int)DRAM_WORDS, (unsigned int)DDR_BASE, (int)bad_load);
    if (bad_load) {
        xil_printf(">>> FAIL: DDR image readback mismatch, aborting\r\n");
        while (1) { }
    }

    // ---- replay the CSR program exactly like tester.v / tb_top_kv260.v ----
    XTime_GetTime(&t_all0);
    for (;;) {
        u32 a = dram_img[ptr] & 0xFU;
        u32 d = dram_img[ptr + 1];
        ptr += 2;

        if (a == 0xEU) {
            break;
        } else if (a == 0xFU) {
            u32 guard = DONE_GUARD;
            layer++;
            XTime_GetTime(&t0);
            csr_wr(CSR_START, 1);
            while (((csr_rd(CSR_DONE) & 1U) == 0U) && (--guard > 0U)) {
                ;
            }
            XTime_GetTime(&t1);
            if (guard == 0U) {
                xil_printf(">>> TIMEOUT: layer %d never asserted done\r\n", layer);
                while (1) { }
            }
            xil_printf("Layer %d done  (%d us)\r\n", layer, (int)elapsed_us(t0, t1));
        } else {
            csr_wr(a, d);
        }
    }
    XTime_GetTime(&t_all1);
    xil_printf("All %d layers done in %d us\r\n", layer, (int)elapsed_us(t_all0, t_all1));

    // ---- compare against golden output ----
    for (i = 0; i < GOLD_N; i++) {
        u32 got = ddr_rd(gold_addr[i]);
        if (got != gold_val[i]) {
            errors++;
            if (errors <= 10) {
                xil_printf("MISMATCH addr=%04x got=%08x exp=%08x\r\n",
                           (unsigned int)gold_addr[i], (unsigned int)got, (unsigned int)gold_val[i]);
            }
        }
    }

    if (errors == 0) {
        xil_printf(">>> PASS: %d/%d golden words match on KV260 hardware\r\n", (int)GOLD_N, (int)GOLD_N);
    } else {
        xil_printf(">>> FAIL: %d/%d mismatches\r\n", (int)errors, (int)GOLD_N);
    }

    while (1) {
        // bare-metal main must not return
    }
    return 0;
}
