/* firmware.c — EE478 Tactile ASIC control chip firmware.
 *
 * Runs on SERV RV32I inside soc_top.v.
 *
 * Three-phase continuous loop:
 *
 *   BOOT INIT
 *     1. BSG_LINK reset sequence (6 writes to BSG_LINK_RESET)
 *     2. Set ADC threshold
 *     3. Kick watchdog
 *     4. Print "BOOT OK\r\n" via UART_TX
 *
 *   Phase 1 — Sensor scan (16x16 = 256 cells)
 *     scan_ctrl autonomously walks all 256 sensor cells via SPI.
 *     adc_8bit_buf is filled by hardware — no firmware loop needed.
 *     ADC_SWAP → flip banks (uart_output_mux reads stable read bank;
 *                             Phase 2 reads live pixels from read bank)
 *
 *   Phase 2 — Offload to DLA (BSG_LINK)
 *     DATA header + 256 ADC pixels + KICKOFF streamed by
 *     bsg_link_upstream_ctl DMA. Firmware writes BSG_UP_GO=1 and
 *     polls BSG_UP_ST[1] (done).
 *
 *   Phase 3 — Wait + status
 *     Poll BSG_UP_ST[2] (pkt_ack) until conv chip signals idle; W1C clear.
 *     (uart_output_mux FSM autonomously builds and sends the 0xB0 packet.)
 *     Read CHIP_STATUS; clear hw error bits; set sw error bits if needed.
 *     Kick watchdog.
 *
 * I2C is handled by the i2c_init hardware block — firmware never touches I2C.
 * All normal UART output is handled by the uart_output_mux FSM.
 * Firmware only writes UART_TX for boot/error strings (priority path).
 *
 * MMIO addresses match soc_top.v and soc_top_arch.md exactly.
 */

#include <stdint.h>
#include "dla_blob.h"   /* dla_inst_flits[] */

/* ── MMIO registers ──────────────────────────────────────────────── */
#define GPIO_OUT        (*(volatile uint32_t *)0x5000)
#define GPIO_IN         (*(volatile uint32_t *)0x5004)

#define SPI_DIV         (*(volatile uint32_t *)0x700C)

/* scan_ctrl — autonomous SPI ADC scanning */
#define SCAN_EN         (*(volatile uint32_t *)0x6000)
#define SCAN_CFG        (*(volatile uint32_t *)0x6004)  /* bit[0]=auto_repeat
                                                           bits[31:16]=settle_cycles */
#define SCAN_ST         (*(volatile uint32_t *)0x6008)  /* bit[0]=busy
                                                           bit[1]=frame_done (W1C)
                                                           bit[2]=spi_err    (W1C) */
#define SCAN_CELL       (*(volatile uint32_t *)0x600C)
#define SCAN_TMO        (*(volatile uint32_t *)0x6010)

/* SCAN_CFG encoding: bits[31:16]=settle_cycles, bit[0]=auto_repeat          */
#define SETTLE_CYCLES        500u   /* 10 us @ 50 MHz                        */
#define SCAN_CFG_VAL(settle, repeat) \
    (((uint32_t)(settle) << 16) | ((uint32_t)(repeat) & 1u))

/* CNN result buffer */
#define CNN_BUF_ST      (*(volatile uint32_t *)0xE000)
#define CNN_BUF_CLR     (*(volatile uint32_t *)0xE004)

/* UART TX (firmware priority path) */
#define UART_TX         (*(volatile uint32_t *)0xA000)
#define UART_ST         (*(volatile uint32_t *)0xA004)

/* BSG_LINK */
#define BSG_TX          (*(volatile uint32_t *)0xC000)
#define BSG_TX_ST       (*(volatile uint32_t *)0xC004)
#define BSG_RX          (*(volatile uint32_t *)0xC008)
#define BSG_RX_ST       (*(volatile uint32_t *)0xC00C)
#define BSG_LINK_RESET  (*(volatile uint32_t *)0xC010)

/* bsg_link_upstream_ctl DMA (base 0xC030) */
#define BSG_UP_CFG      (*(volatile uint32_t *)0xC030)  /* bit[0]=pack_8bit
                                                           bit[1]=full_stream_en
                                                           1=auto-trigger on frame_done */
#define BSG_UP_GO       (*(volatile uint32_t *)0xC034)  /* W: write 1 to trigger */
#define BSG_UP_ST       (*(volatile uint32_t *)0xC038)  /* bit[0]=busy bit[1]=done bit[2]=pkt_ack */
#define BSG_UP_DST      (*(volatile uint32_t *)0xC03C)  /* bits[5:0]=dest_chip_id */
#define BSG_UP_INTVL    (*(volatile uint32_t *)0xC040)  /* 0=manual mode */

/* ── UART helpers ────────────────────────────────────────────────── */

static void uart_putc(char c) {
    while (UART_ST & 1u) { }
    UART_TX = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

/* ── Timing helper ───────────────────────────────────────────────── */

static void settle_delay(void) {
    volatile int i;
    for (i = 0; i < 100; i++) { }
}

/* ── BSG_LINK reset sequence (soc_top_arch.md §7) ───────────────── */
// TODO: Delete this sequence, should be hard reset
static void bsg_link_reset(void) {
    BSG_LINK_RESET = 0x3u;   /* core=1 io=1 tok=0 */
    settle_delay();
    BSG_LINK_RESET = 0x7u;   /* core=1 io=1 tok=1  — tok_clk must NOT toggle */
    settle_delay();
    BSG_LINK_RESET = 0x3u;   /* deassert async_token_reset */
    settle_delay();
    settle_delay();           /* wait >= 4 CLK_IN cycles */
    BSG_LINK_RESET = 0x1u;   /* deassert io_link_reset */
    settle_delay();
    BSG_LINK_RESET = 0x0u;   /* deassert core_link_reset */
    settle_delay();
}

/* ── Phase 1: Autonomous sensor scan via scan_ctrl ───────────────── */

static void phase1_scan(void) {
    /* sck_div=7 → 3.125 MHz @ 50 MHz, settle=8 cycles, auto_repeat=0 */
    SCAN_TMO = 2000u;
    SPI_DIV  = 7u;
    SCAN_CFG = SCAN_CFG_VAL(SETTLE_CYCLES, /*auto_repeat=*/0);

    SCAN_EN = 1u;                     /* kick off — hardware does the rest */

    while (!(SCAN_ST & 0x2u)) { }    /* wait for frame_done (bit[1]) */
    SCAN_ST = 0x2u;                   /* W1C: clear frame_done */
    SCAN_EN = 0u;

    if (SCAN_ST & 0x4u) {            /* spi_err: at least one cell timed out */
        uint32_t err = SCAN_CELL;
        uart_puts("WARN: SPI timeout row=");
        uart_putc('0' + ((err >> 12) & 0xF));
        uart_puts(" col=");
        uart_putc('0' + ((err >>  8) & 0xF));
        uart_puts("\r\n");
        SCAN_ST = 0x4u;              /* W1C: clear spi_err */
    }
}

/* ── One-time DLA program load (called once at boot) ────────────── */

static void dla_load_program(void) {
    int i;
    /* INST packets write the DLA's instruction SRAM. The program is static
     * (11 instructions: load WM, set AM base, 5 CONVs, send_am, halt) and
     * never changes between frames, so it only needs to be sent once. */
    for (i = 0; i < DLA_INST_FLITS_COUNT; i++) {
        while (BSG_TX_ST & 1u) { }
        BSG_TX = dla_inst_flits[i];
    }
}

/* ── Phase 2: per-frame data offload + kickoff via DMA ──────────── */

static void phase2_offload(void) {
    /* Clear CNN result buffer before offload so the new result writes cleanly. */
    CNN_BUF_CLR = 0;

    /* Trigger DMA — hardware streams DATA header + 256 ADC pixels + KICKOFF. */
    BSG_UP_GO = 1u;

    /* Poll until DMA done (BSG_UP_ST[1]) */
    while (!(BSG_UP_ST & 0x2u)) {}
        

    /* W1C: clear done flag for next frame. */
    BSG_UP_ST = 0x2u;

}

/* ── Phase 3: Wait for DLA response, handle status ───────────────── */

static void phase3_wait(void) {
    int ok = 1;

    /* Bounded poll — uart_output_mux will consume BSG_RX and send 0xB0
     * packet autonomously once flits arrive. We just need to confirm
     * the DLA responded before looping back to Phase 1. */
    volatile int timeout_poll = 0;
    while (!(BSG_RX_ST & 1u)) {
        timeout_poll++;
        if (timeout_poll > 10000000) {
            ok = 0;
            break;
        }
    }
    BSG_UP_ST = 0x4u;   /* W1C: clear pkt_ack */
}

/* ── main ────────────────────────────────────────────────────────── */

int main(void) {
    GPIO_OUT = 0;

    /* i2c_init has already programmed the MCP4018 wiper before SERV was
     * released from reset (core_rst_n = rst_n_sync & i2c_done). */

    bsg_link_reset(); // This should be removed

    /* DMA: manual mode, dest=chip 1 (DEFAULT_DEST_ID), pack_8bit=0 */
    BSG_UP_INTVL = 0u;        /* manual trigger mode */
    BSG_UP_DST   = 1u;        /* conv chip ID on ring */
    BSG_UP_CFG   = 0u;        /* pack_8bit=0: one byte per flit */

    /* Load the DLA instruction SRAM once — program never changes between frames. */
    dla_load_program();

    uart_puts("BOOT OK\r\n");

    for (;;) {
        phase1_scan();
        phase2_offload();
        phase3_wait();
    }

    return 0;
}