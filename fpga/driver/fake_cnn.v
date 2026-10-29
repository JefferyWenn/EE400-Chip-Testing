// fake_cnn.v
// Pretends to be the CNN (compute) chip on the other end of the bsg_link.
// For each frame from our chip:
//   0x0404 (DATA header) -> length flit -> pixel flits ... -> 0x0408 (KICKOFF)
// it counts the pixels, checks they are in order, then sends back a
// 14-flit result packet (header 0x0004, length 12, 12 data flits).
// If the KICKOFF never comes (the chip's DMA can drop it), the frame
// ends after a quiet time and "kick_lost" counts it.

module fake_cnn (
    input  wire        clk,
    input  wire        reset,

    // flits coming from the chip
    input  wire [15:0] rx_data,
    input  wire        rx_valid,

    // flits going to the chip
    output wire [15:0] tx_data,
    output wire        tx_valid,
    input  wire        tx_ready,

    // results (for LEDs / HEX)
    output reg  [7:0]  frames,        // frames received
    output reg  [8:0]  last_count,    // pixels in the last frame (256 = all)
    output reg  [7:0]  order_errors,  // pixels that came out of order
    output reg  [7:0]  kick_lost      // frames where KICKOFF never came
);
    localparam IDLE  = 2'd0,  // wait for 0x0404
               LEN   = 2'd1,  // skip the length flit
               BODY  = 2'd2,  // count pixels until 0x0408
               REPLY = 2'd3;  // send the result packet

    reg [1:0] state = IDLE;
    reg [8:0] count;          // pixels seen in this frame
    reg [8:0] last_pixel;     // previous pixel value (to check order)
    reg [3:0] idx;            // which reply flit we are sending
    reg [11:0] quiet;         // clocks since the last flit (in BODY)

    // Reply packet, one flit per idx
    assign tx_data  = (idx == 0) ? 16'h0004 :        // header (DATA type)
                      (idx == 1) ? 16'h000C :        // length = 12
                                   (16'hC000 | idx); // 12 data flits
    assign tx_valid = (state == REPLY);

    always @(posedge clk) begin
        if (reset) begin
            state        <= IDLE;
            frames       <= 0;
            last_count   <= 0;
            order_errors <= 0;
            kick_lost    <= 0;
            idx          <= 0;
        end else begin
            case (state)
                IDLE: if (rx_valid && rx_data == 16'h0404) state <= LEN;

                LEN: if (rx_valid) begin
                    count      <= 0;
                    quiet      <= 0;
                    last_pixel <= 9'h1FF;   // "none yet"
                    state      <= BODY;
                end

                BODY: if (!rx_valid) begin
                    quiet <= quiet + 1'b1;
                    if (quiet == 12'd4000) begin            // no KICKOFF: give up
                        frames     <= frames + 1'b1;
                        last_count <= count;
                        kick_lost  <= kick_lost + 1'b1;
                        idx        <= 0;
                        state      <= REPLY;
                    end
                end else begin
                    quiet <= 0;
                    if (rx_data == 16'h0408) begin          // KICKOFF: frame done
                        frames     <= frames + 1'b1;
                        last_count <= count;
                        idx        <= 0;
                        state      <= REPLY;
                    end else if (rx_data == 16'h0404) begin // new frame started early
                        last_count <= count;
                        state      <= LEN;
                    end else begin                          // a pixel
                        count <= count + 1'b1;
                        if (last_pixel != 9'h1FF && rx_data[8:0] <= last_pixel)
                            order_errors <= order_errors + 1'b1;
                        last_pixel <= rx_data[8:0];
                    end
                end

                REPLY: if (tx_ready) begin                  // one flit sent
                    if (idx == 13) state <= IDLE;
                    else           idx   <= idx + 1'b1;
                end
            endcase
        end
    end
endmodule
