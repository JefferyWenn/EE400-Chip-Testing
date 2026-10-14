// ============================================================
// i2c_init.v — One-shot I2C master for MCP4018 boot config
//
// Fires automatically after reset, sends:
//   START → 0x5E (addr 0x2F + W) → ACK → 0x7D (125) → ACK → STOP
//
// Uses push-pull drive (no open-drain) to fix 550mV issue.
// SCL frequency: 50MHz / (2 * HALF_PERIOD) = ~100kHz
// HALF_PERIOD = 250 → SCL = 50MHz/500 = 100kHz
//
// Ports:
//   done     → high when transaction complete (connect to reset gate)
//   scl_out  → connect directly to io_scl pin
//   sda_out  → connect directly to io_sda pin
// ============================================================

`default_nettype none

module i2c_init #(
    parameter CLK_HZ    = 50_000_000,
    parameter SCL_HZ    = 100_000,
    parameter DEV_ADDR  = 7'h2F,
    parameter WIPER_VAL = 8'h7D
)(
    input  wire clk,
    input  wire rst,
    output wire scl_out,
    output wire sda_out,
    output reg  done
);

// ── Clock divider ─────────────────────────────────────────────
localparam HALF = CLK_HZ / (SCL_HZ * 2);  // = 250 cycles

reg [$clog2(HALF+1)-1:0] clk_cnt;
reg                        tick;  // fires every half-period

always_ff @(posedge clk) begin
    if (rst) begin
        clk_cnt <= 0;
        tick    <= 0;
    end else if (clk_cnt == HALF-1) begin
        clk_cnt <= 0;
        tick    <= 1;
    end else begin
        clk_cnt <= clk_cnt + 1;
        tick    <= 0;
    end
end

// ── Build the full bit sequence ───────────────────────────────
// Each bit = 2 ticks (one SCL low half, one SCL high half)
// Sequence:
//   START:  SDA=1,SCL=1 → SDA=0,SCL=1 → SDA=0,SCL=0
//   8 bits addr+W (0x5E): SCL low+high per bit, SDA=bit
//   ACK:    SDA=1, SCL low+high (ignore ACK value)
//   8 bits wiper (0x7D):  SCL low+high per bit, SDA=bit
//   ACK:    SDA=1, SCL low+high
//   STOP:   SDA=0,SCL=0 → SDA=0,SCL=1 → SDA=1,SCL=1

localparam ADDR_BYTE  = {DEV_ADDR, 1'b0};  // 0x5E
localparam DATA_BYTE  = WIPER_VAL;          // 0x7D

// State machine states
localparam  S_IDLE      = 6'd0,
            S_START1    = 6'd1,  // SDA=1 SCL=1
            S_START2    = 6'd2,  // SDA=0 SCL=1 (start condition)
            S_START3    = 6'd3,  // SDA=0 SCL=0
            // addr bits [7:0] × 2 ticks each = states 4..19
            S_ADDR_LO   = 6'd4,  // SCL low,  SDA=bit
            S_ADDR_HI   = 6'd5,  // SCL high, SDA=bit
            // ACK1
            S_ACK1_LO   = 6'd6,
            S_ACK1_HI   = 6'd7,
            // data bits × 2 ticks
            S_DATA_LO   = 6'd8,
            S_DATA_HI   = 6'd9,
            // ACK2
            S_ACK2_LO   = 6'd10,
            S_ACK2_HI   = 6'd11,
            // STOP
            S_STOP1     = 6'd12,  // SDA=0 SCL=0
            S_STOP2     = 6'd13,  // SDA=0 SCL=1
            S_STOP3     = 6'd14,  // SDA=1 SCL=1
            S_DONE      = 6'd15;

reg [5:0]  state;
reg [2:0]  bit_idx;   // counts 7 down to 0
reg        scl_r;
reg        sda_r;

assign scl_out = scl_r;
assign sda_out = sda_r;

always_ff @(posedge clk) begin
    if (rst) begin
        state   <= S_IDLE;
        bit_idx <= 3'd7;
        scl_r   <= 1'b1;
        sda_r   <= 1'b1;
        done    <= 1'b0;
    end else if (tick) begin
        case (state)

        S_IDLE: begin
            scl_r <= 1'b1;
            sda_r <= 1'b1;
            state <= S_START1;
        end

        // ── START condition ───────────────────────────────────
        S_START1: begin
            scl_r <= 1'b1;
            sda_r <= 1'b1;
            state <= S_START2;
        end
        S_START2: begin
            scl_r <= 1'b1;
            sda_r <= 1'b0;  // SDA falls while SCL high = START
            state <= S_START3;
        end
        S_START3: begin
            scl_r <= 1'b0;
            sda_r <= 1'b0;
            bit_idx <= 3'd7;
            state <= S_ADDR_LO;
        end

        // ── Address byte 0x5E ─────────────────────────────────
        S_ADDR_LO: begin
            scl_r <= 1'b0;
            sda_r <= ADDR_BYTE[bit_idx];
            state <= S_ADDR_HI;
        end
        S_ADDR_HI: begin
            scl_r <= 1'b1;  // rising edge — MCP4018 samples SDA
            sda_r <= ADDR_BYTE[bit_idx];
            if (bit_idx == 0) begin
                state <= S_ACK1_LO;
            end else begin
                bit_idx <= bit_idx - 1;
                state   <= S_ADDR_LO;
            end
        end

        // ── ACK 1 (ignore value) ──────────────────────────────
        S_ACK1_LO: begin
            scl_r <= 1'b0;
            sda_r <= 1'b1;  // release SDA for ACK
            state <= S_ACK1_HI;
        end
        S_ACK1_HI: begin
            scl_r   <= 1'b1;
            sda_r   <= 1'b1;
            bit_idx <= 3'd7;
            state   <= S_DATA_LO;
        end

        // ── Data byte 0x7D ────────────────────────────────────
        S_DATA_LO: begin
            scl_r <= 1'b0;
            sda_r <= DATA_BYTE[bit_idx];
            state <= S_DATA_HI;
        end
        S_DATA_HI: begin
            scl_r <= 1'b1;
            sda_r <= DATA_BYTE[bit_idx];
            if (bit_idx == 0) begin
                state <= S_ACK2_LO;
            end else begin
                bit_idx <= bit_idx - 1;
                state   <= S_DATA_LO;
            end
        end

        // ── ACK 2 (ignore value) ──────────────────────────────
        S_ACK2_LO: begin
            scl_r <= 1'b0;
            sda_r <= 1'b1;
            state <= S_ACK2_HI;
        end
        S_ACK2_HI: begin
            scl_r <= 1'b1;
            sda_r <= 1'b1;
            state <= S_STOP1;
        end

        // ── STOP condition ────────────────────────────────────
        S_STOP1: begin
            scl_r <= 1'b0;
            sda_r <= 1'b0;
            state <= S_STOP2;
        end
        S_STOP2: begin
            scl_r <= 1'b1;
            sda_r <= 1'b0;
            state <= S_STOP3;
        end
        S_STOP3: begin
            scl_r <= 1'b1;
            sda_r <= 1'b1;  // SDA rises while SCL high = STOP
            state <= S_DONE;
        end

        S_DONE: begin
            scl_r <= 1'b1;
            sda_r <= 1'b1;
            done  <= 1'b1;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
`default_nettype wire