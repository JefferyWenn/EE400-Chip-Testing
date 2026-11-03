// Turns the counters into steady numbers for the LEDs and HEX.

module status (
    input  logic       clk,
    input  logic       reset,
    input  logic       freeze,
    input  logic [7:0] frames,
    input  logic [8:0] last_count,
    input  logic [7:0] order_errors,
    input  logic [7:0] kick_lost,
    input  logic [7:0] packets,
    input  logic [7:0] peak_val,
    input  logic [7:0] peak_pos,

    output logic [7:0] show_fps   = 0,
    output logic [7:0] show_peak  = 0,
    output logic [7:0] show_pos   = 0,
    output logic       any_frame  = 0,
    output logic       any_short  = 0,
    output logic       any_kick   = 0,
    output logic       any_packet = 0
);
    localparam HALF_SEC = 25'd25_000_000;  // 0.5 s at 50 MHz

    logic [7:0] frames_d = 0;
    always @(posedge clk) frames_d <= frames;

    logic new_frame;
    assign new_frame = (frames != frames_d);

    // these stay on until reset
    logic [8:0] worst = 9'h1FF;
    always @(posedge clk) begin
        if (reset) begin
            worst <= 9'h1FF; any_frame <= 0; any_short <= 0;
            any_kick <= 0; any_packet <= 0;
        end else begin
            if (new_frame) begin
                any_frame <= 1;
                if (last_count < worst)    worst     <= last_count;
                if (last_count != 9'd256)  any_short <= 1;
            end
            if (kick_lost != 0) any_kick   <= 1;
            if (packets   != 0) any_packet <= 1;
        end
    end

    // fps = frames counted over the last second
    logic [24:0] t = 0;
    logic        second = 0;
    logic [7:0]  frames_at_sec = 0;
    logic [7:0]  fps = 0;
    logic        tick;
    assign tick = (t == HALF_SEC - 1);

    always @(posedge clk) begin
        t <= tick ? 25'd0 : t + 1'b1;
        if (tick) begin
            second <= ~second;
            if (second) begin
                fps           <= frames - frames_at_sec;
                frames_at_sec <= frames;
            end
        end
    end

    // HEX updates twice a second
    always @(posedge clk) begin
        if (reset) begin
            show_fps <= 0; show_peak <= 0; show_pos <= 0;
        end else if (tick && !freeze) begin
            show_fps  <= fps;
            show_peak <= peak_val;
            show_pos  <= peak_pos;
        end
    end
endmodule
