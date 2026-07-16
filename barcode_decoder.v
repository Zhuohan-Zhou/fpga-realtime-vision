// barcode_decoder.v -- Code 39 barcode reader, digits 0-9 only, single
// fixed scanline.
//
// Deliberately does NOT track a moving object the way color_blob_tracker.v
// does. A conveyor-line barcode reader normally works the opposite way:
// the camera/scan zone stays put and the product carries the barcode
// through it, so every frame can be decoded completely independently --
// no cross-frame prediction, no search window, nothing to "lose track of".
// That sidesteps the fast/erratic-motion problems discussed for the
// centroid tracker; the real speed limit here is motion blur from the
// sensor's own exposure time, not this logic (see CLAUDE.md).
//
// Per frame, scans ONE fixed row (SCAN_ROW):
//   luma < THRESH -> "bar" (dark), else "space" (light)
//   run-length encode consecutive same-color pixels along that row
//   classify each completed run as narrow/wide by comparing its pixel
//     length against WIDE_THRESH -- a fixed absolute threshold, which
//     assumes the barcode's on-screen size stays roughly constant (true
//     for a fixed camera-to-belt distance on a real line; needs retuning
//     if that distance changes)
//
// Code 39: every character (digit 0-9, or the start/stop "*") is 9
// elements -- 5 bars + 4 spaces, alternating, exactly 3 of the 9 wide.
// The narrow/wide patterns in decode_digit() below are the verified
// reference encoding, cross-checked against the lookup table in a
// widely-used open-source barcode library (python-barcode), not
// hand-derived from memory. Characters are separated by one extra narrow
// space that isn't part of the 9-element pattern -- S_SKIP_GAP consumes it.
//
// V1 scope: digits only (no letters/symbols), single scanline (no
// multi-row voting/averaging for robustness), fixed absolute width
// threshold (no adaptive per-scan module-width estimation). Decoded
// digits come out as raw ports for SignalTap / driving further logic;
// on-screen rendering of the actual digit text isn't built yet --
// camera_display_top.v just tints the reference scanline to show
// searching vs. a fresh valid decode.
module barcode_decoder #(
    parameter [10:0] SCAN_ROW    = 11'd136,  // which row to scan (~vertical center, 272-tall panel)
    parameter [7:0]  THRESH      = 8'd128,   // luma threshold: below = bar(dark), else = space(light)
    parameter [10:0] WIDE_THRESH = 11'd12,   // run length (px) >= this => "wide" -- retune to your setup
    parameter [3:0]  MAX_DIGITS  = 4'd8
)(
    input             clk,       // clk_9m
    input             rst_n,
    input             de,        // pixel valid strobe (lcd_de_w)
    input             frame_pulse,
    input      [7:0]  y8,
    input      [10:0] pixel_x,
    input      [10:0] pixel_y,

    output reg        barcode_valid,    // 1-cycle pulse: fresh decode completed this frame
    output reg [3:0]  digit_count,      // digits in the last successful decode
    output reg [31:0] decoded_digits,   // MAX_DIGITS*4 bits packed, digit 0 in the low nibble
    output            scan_active       // 1 while (pixel_y==SCAN_ROW && de) -- draw the reference line
);

localparam [8:0] PAT_START = 9'b010010100;   // '*' -- same pattern for start and stop

assign scan_active = de && (pixel_y == SCAN_ROW);

wire is_bar = (y8 < THRESH);

reg        run_color;      // color of the run currently being measured
reg [10:0] run_len;
reg        run_active;     // a run is currently open on this row

wire new_run_break = scan_active && run_active && (is_bar != run_color);

// combinational "what the history register WILL be if this run closes out
// now" -- used instead of the (one-cycle-stale) hist_nw register itself
// for every decision made in the same cycle a run actually closes.
wire       nw_bit_now   = (run_len >= WIDE_THRESH);
reg  [8:0] hist_nw;
wire [8:0] hist_nw_next = {hist_nw[7:0], nw_bit_now};
wire       pending_is_start = (hist_nw_next == PAT_START);

function [4:0] decode_digit;   // {valid, 4-bit digit}; patterns verified,
    input [8:0] pat;           // see file header
    begin
        case (pat)
            9'b000110100: decode_digit = {1'b1, 4'd0};
            9'b100100001: decode_digit = {1'b1, 4'd1};
            9'b001100001: decode_digit = {1'b1, 4'd2};
            9'b101100000: decode_digit = {1'b1, 4'd3};
            9'b000110001: decode_digit = {1'b1, 4'd4};
            9'b100110000: decode_digit = {1'b1, 4'd5};
            9'b001110000: decode_digit = {1'b1, 4'd6};
            9'b000100101: decode_digit = {1'b1, 4'd7};
            9'b100100100: decode_digit = {1'b1, 4'd8};
            9'b001100100: decode_digit = {1'b1, 4'd9};
            default:       decode_digit = {1'b0, 4'd0};
        endcase
    end
endfunction

wire [4:0] pending_char = decode_digit(hist_nw_next);

localparam S_HUNT         = 2'd0,   // sliding-window hunting for the start '*'
           S_SKIP_GAP     = 2'd1,   // consuming the inter-character narrow gap
           S_CHAR_COLLECT = 2'd2;   // counting off one character's 9 elements

reg [1:0]  state;
reg [3:0]  elem_cnt;         // 0..8 within the character currently being counted
reg [3:0]  cur_digit_count;
reg [31:0] cur_digits;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        run_color       <= 1'b0;
        run_len         <= 11'd0;
        run_active      <= 1'b0;
        hist_nw         <= 9'd0;
        state           <= S_HUNT;
        elem_cnt        <= 4'd0;
        cur_digit_count <= 4'd0;
        cur_digits      <= 32'd0;
        barcode_valid   <= 1'b0;
        digit_count     <= 4'd0;
        decoded_digits  <= 32'd0;
    end
    else begin
        barcode_valid <= 1'b0;

        if (frame_pulse) begin
            // each frame's scanline is decoded from scratch -- no memory
            // of where a previous frame's attempt got to.
            run_active      <= 1'b0;
            hist_nw         <= 9'd0;
            state           <= S_HUNT;
            elem_cnt        <= 4'd0;
            cur_digit_count <= 4'd0;
            cur_digits      <= 32'd0;
        end
        else if (scan_active) begin
            if (!run_active) begin
                run_color  <= is_bar;
                run_len    <= 11'd1;
                run_active <= 1'b1;
            end
            else if (new_run_break) begin
                hist_nw <= hist_nw_next;

                case (state)
                    S_HUNT: begin
                        if (pending_is_start) begin
                            state           <= S_SKIP_GAP;
                            cur_digit_count <= 4'd0;
                            cur_digits      <= 32'd0;
                        end
                    end

                    S_SKIP_GAP: begin
                        // this run is the inter-character gap -- just consume it
                        state    <= S_CHAR_COLLECT;
                        elem_cnt <= 4'd0;
                    end

                    S_CHAR_COLLECT: begin
                        if (elem_cnt == 4'd8) begin
                            if (pending_is_start) begin
                                // stop character -- decode complete
                                if (cur_digit_count > 4'd0) begin
                                    barcode_valid  <= 1'b1;
                                    digit_count    <= cur_digit_count;
                                    decoded_digits <= cur_digits;
                                end
                                state <= S_HUNT;
                            end
                            else if (pending_char[4] && (cur_digit_count < MAX_DIGITS)) begin
                                cur_digits[cur_digit_count*4 +: 4] <= pending_char[3:0];
                                cur_digit_count <= cur_digit_count + 4'd1;
                                state <= S_SKIP_GAP;
                            end
                            else begin
                                // not a digit, not stop, or ran out of room -- abandon
                                // this attempt and go back to hunting
                                state <= S_HUNT;
                            end
                        end
                        else begin
                            elem_cnt <= elem_cnt + 4'd1;
                        end
                    end

                    default: state <= S_HUNT;
                endcase

                run_color <= is_bar;
                run_len   <= 11'd1;
            end
            else begin
                run_len <= run_len + 11'd1;
            end
        end
        else begin
            run_active <= 1'b0;
        end
    end
end

endmodule
