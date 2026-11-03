// Acts as the CNN chip on the other end of the link.
// Counts the pixels in each frame, finds the strongest press,
// and sends a 14-flit result packet back.

module fake_cnn (
    input  logic        clk,
    input  logic        reset,

    input  logic [15:0] rx_data,
    input  logic        rx_valid,

    output logic [15:0] tx_data,
    output logic        tx_valid,
    input  logic        tx_ready,

    output logic [7:0]  frames,
    output logic [8:0]  last_count,
    output logic [7:0]  order_errors,
    output logic [7:0]  kick_lost,
    output logic [7:0]  peak_val,
    output logic [7:0]  peak_pos      // {row, col}
);
    localparam IDLE  = 2'd0,
               LEN   = 2'd1,
               BODY  = 2'd2,
               REPLY = 2'd3;

    logic [1:0]  state = IDLE;
    logic [8:0]  count;
    logic [8:0]  last_pixel;
    logic [3:0]  idx;
    logic [11:0] quiet;
    logic [7:0]  max_val;
    logic [7:0]  max_pos;

    // the ADC value goes down when you press, so flip it
    logic [7:0] press;
    assign press = ~rx_data[7:0];

    // reply: header, length 12, then 12 data flits
    assign tx_data  = (idx == 0) ? 16'h0004 :
                      (idx == 1) ? 16'h000C :
                                   (16'hC000 | idx);
    assign tx_valid = (state == REPLY);

    always @(posedge clk) begin
        if (reset) begin
            state        <= IDLE;
            frames       <= 0;
            last_count   <= 0;
            order_errors <= 0;
            kick_lost    <= 0;
            peak_val     <= 0;
            peak_pos     <= 0;
            idx          <= 0;
        end else begin
            case (state)
                IDLE: if (rx_valid && rx_data == 16'h0404) state <= LEN;

                LEN: if (rx_valid) begin
                    count      <= 0;
                    quiet      <= 0;
                    last_pixel <= 9'h1FF;
                    max_val    <= 0;
                    max_pos    <= 0;
                    state      <= BODY;
                end

                BODY: if (!rx_valid) begin
                    quiet <= quiet + 1'b1;
                    // KICKOFF never came, end the frame anyway
                    if (quiet == 12'd4000) begin
                        frames     <= frames + 1'b1;
                        last_count <= count;
                        kick_lost  <= kick_lost + 1'b1;
                        idx        <= 0;
                        state      <= REPLY;
                    end
                end else begin
                    quiet <= 0;
                    if (rx_data == 16'h0408) begin          // KICKOFF
                        frames     <= frames + 1'b1;
                        last_count <= count;
                        peak_val   <= max_val;
                        peak_pos   <= max_pos;
                        idx        <= 0;
                        state      <= REPLY;
                    end else if (rx_data == 16'h0404) begin
                        last_count <= count;
                        state      <= LEN;
                    end else begin                          // pixel
                        count <= count + 1'b1;
                        if (last_pixel != 9'h1FF && rx_data[8:0] <= last_pixel)
                            order_errors <= order_errors + 1'b1;
                        last_pixel <= rx_data[8:0];
                        if (press > max_val) begin
                            max_val <= press;
                            max_pos <= count[7:0];
                        end
                    end
                end

                REPLY: if (tx_ready) begin
                    if (idx == 13) state <= IDLE;
                    else           idx   <= idx + 1'b1;
                end
            endcase
        end
    end
endmodule
