/* firmware.c - control chip firmware (runs on the SERV RISC-V CPU)
 *
 * Boot:   send the CNN program (44 flits) once, print "BOOT OK"
 * Loop:   1. scan all 256 sensor cells (hardware scan_ctrl does the work)
 *         2. send the frame to the CNN chip, flit by flit
 *         3. wait for the CNN result (hardware sends it out as a 0xB0 packet)
 *
 * Fixes compared to the tapeout firmware:
 *   - frames are sent by the CPU, not the DMA engine (the DMA drops flits)
 *   - waits on the CNN result buffer (0xE000) instead of BSG_RX_ST
 */

#include <stdint.h>
#include "dla_blob.h"

#define REG(addr) (*(volatile uint32_t *)(addr))

/* Sensor scan (scan_ctrl) */
#define SCAN_EN     REG(0x6000)   /* 1 = start a scan                   */
#define SCAN_CFG    REG(0x6004)   /* [31:16] settle clocks, [0] repeat  */
#define SCAN_ST     REG(0x6008)   /* [1] frame done (write 1 to clear)  */
#define SCAN_TMO    REG(0x6010)   /* SPI timeout per cell               */
#define SPI_DIV     REG(0x700C)   /* SPI clock divider                  */

/* ADC frame buffer: pixel i is read at 0x8600 + 4*i */
#define ADC_PIXEL(i) REG(0x8600 + 4 * (i))

/* UART */
#define UART_TX     REG(0xA000)
#define UART_ST     REG(0xA004)   /* [0] busy */

/* Link to the CNN chip (CPU path) */
#define BSG_TX      REG(0xC000)   /* write one 16-bit flit              */
#define BSG_TX_ST   REG(0xC004)   /* [0] 1 = link full, wait            */

/* CNN result buffer */
#define CNN_BUF_ST  REG(0xE000)   /* [0] 1 = result received            */

static void uart_puts(const char *s)
{
    while (*s) {
        while (UART_ST & 1) { }
        UART_TX = *s++;
    }
}

static void send_flit(uint32_t flit)
{
    while (BSG_TX_ST & 1) { }     /* wait until the link can take it */
    BSG_TX = flit;
}

static void scan_frame(void)
{
    SPI_DIV  = 7;                 /* SPI clock = core clock / 16        */
    SCAN_TMO = 2000;
    SCAN_CFG = 500u << 16;        /* settle time per cell, no repeat    */
    SCAN_EN  = 1;
    while (!(SCAN_ST & 2)) { }    /* wait for frame done                */
    SCAN_ST  = 2;                 /* clear it                           */
    SCAN_EN  = 0;
}

static void send_frame(void)
{
    send_flit(0x0404);            /* DATA header                        */
    send_flit(0x0100);            /* length = 256 pixels                */
    for (int i = 0; i < 256; i++)
        send_flit(ADC_PIXEL(i));  /* one pixel per flit                 */
    send_flit(0x0408);            /* KICKOFF: start the CNN             */
    send_flit(0x0000);
}

static void wait_result(void)
{
    for (int t = 0; t < 100000; t++)   /* give up after a while       */
        if (CNN_BUF_ST & 1) return;
}

int main(void)
{
    for (int i = 0; i < DLA_INST_FLITS_COUNT; i++)
        send_flit(dla_inst_flits[i]);  /* CNN program, once            */

    uart_puts("BOOT OK\r\n");

    for (;;) {
        scan_frame();
        send_frame();
        wait_result();
    }
}
