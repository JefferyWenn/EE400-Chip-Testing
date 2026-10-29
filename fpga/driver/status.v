// status.v
// Turns the fast-changing counters into steady values for LEDs and HEX:
//   - fps          : frames in the last second (updated once per second)
//   - worst_count  : fewest pixels seen in any frame since reset
//   - sticky flags : once something happened, it stays on until reset
//   - the HEX values refresh twice per second, and "freeze" holds them

module status (
    input  wire       clk,           // 12.5 MHz
    input  wire       reset,
    input  wire       freeze,        // 1 = hold the HEX values
    input  wire [7:0] frames,        // running frame count (wraps at 256)
    input  wire [8:0] last_count,    // pixels in the latest frame
    input  wire [7:0] order_errors,  // running count
    input  wire [7:0] kick_lost,     // running count
    input  wire [7:0] packets,       // running count of 0xB0 bytes
    input  wire [7:0] peak_val,      // strongest pixel in the last frame
    input  wire [7:0] peak_pos,      // its position {row, col}

    output reg  [7:0] show_fps   = 0,   // for HEX5-4
    output reg  [7:0] show_peak  = 0,   // for HEX3-2
    output reg  [7:0] show_pos   = 0,   // for HEX1-0
    output reg        any_frame  = 0,   // a frame has arrived
    output reg        any_short  = 0,   // some frame had < 256 pixels
    output reg        any_kick   = 0,   // some KICKOFF was lost
    output reg        any_packet = 0    // a result packet came back
);
    localparam HALF_SEC = 23'd6_250_000;   // 0.5 s at 12.5 MHz

    // ---- New frame? (frame counter changed) ----
    reg [7:0] frames_d = 0;
    always @(posedge clk) frames_d <= frames;
    wire new_frame = (frames != frames_d);

    // ---- Sticky flags and worst pixel count ----
    reg [8:0] worst = 9'h1FF;
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

    // ---- Half-second tick, and frames per second ----
    reg [22:0] t = 0;
    reg        second = 0;          // toggles every 0.5 s
    reg [7:0]  frames_at_sec = 0;   // frame count one second ago
    reg [7:0]  fps = 0;
    wire tick = (t == HALF_SEC - 1);

    always @(posedge clk) begin
        t <= tick ? 23'd0 : t + 1'b1;
        if (tick) begin
            second <= ~second;
            if (second) begin                       // every 1 s
                fps           <= frames - frames_at_sec;
                frames_at_sec <= frames;
            end
        end
    end

    // ---- What the HEX shows: refresh twice per second unless frozen ----
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
