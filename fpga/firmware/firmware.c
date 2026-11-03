/* Firmware for the chip's SERV CPU.
 * At boot: send the CNN program, print BOOT OK.
 * Then forever: scan the glove, send the frame, wait for the result.
 * The CPU sends the frame itself because the chip's DMA drops flits.
 */

#include <stdint.h>
#include "dla_blob.h"

#define REG(addr) (*(volatile uint32_t *)(addr))

#define SCAN_EN     REG(0x6000)
#define SCAN_CFG    REG(0x6004)   /* settle clocks in [31:16] */
#define SCAN_ST     REG(0x6008)   /* bit 1 = frame done */
#define SCAN_TMO    REG(0x6010)
#define SPI_DIV     REG(0x700C)

#define ADC_PIXEL(i) REG(0x8600 + 4 * (i))

#define UART_TX     REG(0xA000)
#define UART_ST     REG(0xA004)   /* bit 0 = busy */

#define BSG_TX      REG(0xC000)
#define BSG_TX_ST   REG(0xC004)   /* bit 0 = full */

#define CNN_BUF_ST  REG(0xE000)   /* bit 0 = result is back */

static void uart_puts(const char *s)
{
    while (*s) {
        while (UART_ST & 1) { }
        UART_TX = *s++;
    }
}

static void send_flit(uint32_t flit)
{
    while (BSG_TX_ST & 1) { }
    BSG_TX = flit;
}

static void scan_frame(void)
{
    SPI_DIV  = 7;
    SCAN_TMO = 2000;
    SCAN_CFG = 500u << 16;        /* 10 us per cell at 50 MHz */
    SCAN_EN  = 1;
    while (!(SCAN_ST & 2)) { }
    SCAN_ST  = 2;
    SCAN_EN  = 0;
}

static void send_frame(void)
{
    send_flit(0x0404);            /* header */
    send_flit(0x0100);            /* 256 pixels */
    for (int i = 0; i < 256; i++)
        send_flit(ADC_PIXEL(i));
    send_flit(0x0408);            /* start the CNN */
    send_flit(0x0000);
}

static void wait_result(void)
{
    for (int t = 0; t < 100000; t++)
        if (CNN_BUF_ST & 1) return;
}

int main(void)
{
    for (int i = 0; i < DLA_INST_FLITS_COUNT; i++)
        send_flit(dla_inst_flits[i]);

    uart_puts("BOOT OK\r\n");

    for (;;) {
        scan_frame();
        send_frame();
        wait_result();
    }
}
