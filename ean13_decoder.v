// ean13_decoder.v -- EAN-13 / UPC-A barcode reader, single fixed scanline.
//
// Replaces barcode_decoder.v (Code 39) on key2: real retail packaging
// (the drink-box case this was built for) is printed in EAN-13/UPC-A, not
// Code 39 -- Code 39 is an industrial/logistics symbology (asset tags,
// badges), essentially never seen on consumer goods. UPC-A needs no
// separate handling: it's formatted as EAN-13 with an implied leading
// digit of 0 (LEFT_PATTERN[0] = all-A), so an EAN-13 decoder reads UPC-A
// barcodes correctly with zero extra logic.
//
// Same "fixed scan zone, no cross-frame state" philosophy as
// barcode_decoder.v (see that file's header for the production-line
// rationale) -- frame_pulse wipes all state, every frame is decoded from
// scratch.
//
// -------------------------------------------------------------------
// Why this is a bigger module than Code 39: Code 39 only has two width
// classes (narrow/wide) and a fixed absolute pixel threshold was good
// enough. EAN-13 packs each digit into 7 modules split across 4 runs,
// where each run can be 1, 2, 3 or 4 modules wide (all in the *same*
// physical module width X) -- a single narrow/wide split can't represent
// that. Instead this module estimates X dynamically, once per scan, from
// the start guard pattern "101" (3 modules, each exactly 1X): the 3 guard
// runs are checked for being mutually close in width (ratio test, no
// division: 2*max <= 3*min), and if so their average becomes X_est
// (approximated as sum*683>>11 =~ sum/3, cheap single-cycle shift-add,
// avoids a division for something computed on a hot path). Every
// subsequent run is then classified into 1..4 modules by comparing
// 2*run_width against 3*X_est/5*X_est/7*X_est (i.e. the 1.5X/2.5X/3.5X
// bucket boundaries, cross-multiplied by 2 to dodge fractional math).
//
// Structure decoded (95 modules total):
//   start guard "101" (3) -> 6 left digits x 7 modules (42) -> middle
//   guard "01010" (5) -> 6 right digits x 7 modules (42) -> end guard
//   "101" (3)
// Left digits use one of two 10-entry code tables (called "A"/"B" below,
// matching the standard's own naming) selected per-digit; which A/B
// pattern was used across all 6 left digits implies the leading (13th,
// never-directly-encoded) digit via a reverse lookup table. Right digits
// use a single table ("C"). All three tables plus the A/B-pattern-to-
// leading-digit table were pulled from python-barcode's
// barcode/charsets/ean.py (same verification approach as Code 39's
// tables in barcode_decoder.v) and converted to run-length tuples with a
// small script -- not hand-derived from memory. Verified uniqueness: all
// 20 left (A+B) run-tuples are distinct, all 10 right run-tuples are
// distinct.
//
// Checksum: the standard's own weighted mod-10 check (weight 1 on the
// digit itself + digits 2,4 positions later, weight 3 on the others) is
// verified before ean_valid is allowed to pulse -- this is effectively
// free once all 13 digits are decoded, and it's real protection against a
// misclassified run silently producing a plausible-looking wrong number,
// which the 1.5X-style thresholding can't fully rule out on its own.
// Also gated on the left digits' A/B pattern actually being one of the
// 10 legal LEFT_PATTERN combinations (out of 2^6=64 possible), not just
// "each individual digit decoded to something".
module ean13_decoder #(
    parameter [10:0] SCAN_ROW      = 11'd136,
    parameter [7:0]  THRESH        = 8'd128,
    parameter [10:0] MIN_MODULE_PX = 11'd3   // reject guard candidates narrower than this (noise)
)(
    input             clk,       // clk_9m
    input             rst_n,
    input             de,        // lcd_de_w
    input             frame_pulse,
    input      [7:0]  y8,
    input      [10:0] pixel_x,
    input      [10:0] pixel_y,

    output reg        ean_valid,        // 1-cycle pulse: fresh, checksum-passing decode
    output reg [51:0] decoded_digits,   // 13 x 4-bit BCD nibbles, digit0 (leading) in the low nibble
    output            scan_active
);

assign scan_active = de && (pixel_y == SCAN_ROW);

wire is_bar = (y8 < THRESH);

reg        run_color;
reg [10:0] run_len;
reg        run_active;

wire new_run_break = scan_active && run_active && (is_bar != run_color);

// ---- module-width estimate ----
reg [10:0] X_est;
reg [10:0] hist_w1, hist_w2;   // widths of the 2 runs before the one closing now
reg [1:0]  run_seen_count;     // saturates at 3 -- need >=2 prior runs before guard-checking

wire [10:0] gmin_ab = (hist_w2 < hist_w1) ? hist_w2 : hist_w1;
wire [10:0] gmin    = (gmin_ab < run_len) ? gmin_ab : run_len;
wire [10:0] gmax_ab = (hist_w2 > hist_w1) ? hist_w2 : hist_w1;
wire [10:0] gmax    = (gmax_ab > run_len) ? gmax_ab : run_len;

wire guard_ratio_ok = (gmax << 1) <= (gmin * 3);
wire guard_match = run_color && (run_seen_count >= 2'd2) &&
                    (gmin >= MIN_MODULE_PX) && guard_ratio_ok;

wire [12:0] guard_sum3   = hist_w2 + hist_w1 + run_len;
wire [23:0] guard_sum3_x = guard_sum3 * 24'd683;   // *683/2048 =~ /3
wire [10:0] X_est_next   = guard_sum3_x[23:11];

// ---- run -> module-count classifier (1..4), using the current X_est ----
function [2:0] classify_mod;
    input [10:0] w;
    input [10:0] xest;
    reg [11:0] w2;
    reg [12:0] x3, x5, x7;
    begin
        w2 = {1'b0, w} << 1;
        x3 = ({2'b0, xest} << 1) + {2'b0, xest};
        x5 = ({2'b0, xest} << 2) + {2'b0, xest};
        x7 = ({2'b0, xest} << 3) - {2'b0, xest};
        if      (w2 < x3) classify_mod = 3'd1;
        else if (w2 < x5) classify_mod = 3'd2;
        else if (w2 < x7) classify_mod = 3'd3;
        else               classify_mod = 3'd4;
    end
endfunction

wire [2:0] n_now = classify_mod(run_len, X_est);

// ---- 4-run digit lookup (left: A/B tables; right: C table) ----
reg [2:0] mh0, mh1, mh2;   // module counts of this digit's first 3 runs
wire [11:0] key12 = {mh0, mh1, mh2, n_now};

reg       left_setbit, left_valid;
reg [3:0] left_digit;
always @* begin
    left_setbit = 1'b0;
    left_digit  = 4'd0;
    left_valid  = 1'b0;
    case (key12)
        12'b001001001100: begin left_setbit = 1'b0; left_digit = 4'd6; left_valid = 1'b1; end
        12'b001001010011: begin left_setbit = 1'b1; left_digit = 4'd0; left_valid = 1'b1; end
        12'b001001011010: begin left_setbit = 1'b0; left_digit = 4'd4; left_valid = 1'b1; end
        12'b001001100001: begin left_setbit = 1'b1; left_digit = 4'd3; left_valid = 1'b1; end
        12'b001010001011: begin left_setbit = 1'b0; left_digit = 4'd8; left_valid = 1'b1; end
        12'b001010010010: begin left_setbit = 1'b1; left_digit = 4'd1; left_valid = 1'b1; end
        12'b001010011001: begin left_setbit = 1'b0; left_digit = 4'd5; left_valid = 1'b1; end
        12'b001011001010: begin left_setbit = 1'b0; left_digit = 4'd7; left_valid = 1'b1; end
        12'b001011010001: begin left_setbit = 1'b1; left_digit = 4'd5; left_valid = 1'b1; end
        12'b001100001001: begin left_setbit = 1'b0; left_digit = 4'd3; left_valid = 1'b1; end
        12'b010001001011: begin left_setbit = 1'b1; left_digit = 4'd9; left_valid = 1'b1; end
        12'b010001010010: begin left_setbit = 1'b0; left_digit = 4'd2; left_valid = 1'b1; end
        12'b010001011001: begin left_setbit = 1'b1; left_digit = 4'd7; left_valid = 1'b1; end
        12'b010010001010: begin left_setbit = 1'b1; left_digit = 4'd2; left_valid = 1'b1; end
        12'b010010010001: begin left_setbit = 1'b0; left_digit = 4'd1; left_valid = 1'b1; end
        12'b010011001001: begin left_setbit = 1'b1; left_digit = 4'd4; left_valid = 1'b1; end
        12'b011001001010: begin left_setbit = 1'b0; left_digit = 4'd9; left_valid = 1'b1; end
        12'b011001010001: begin left_setbit = 1'b1; left_digit = 4'd8; left_valid = 1'b1; end
        12'b011010001001: begin left_setbit = 1'b0; left_digit = 4'd0; left_valid = 1'b1; end
        12'b100001001001: begin left_setbit = 1'b1; left_digit = 4'd6; left_valid = 1'b1; end
        default: ;
    endcase
end

reg       right_valid;
reg [3:0] right_digit;
always @* begin
    right_digit = 4'd0;
    right_valid = 1'b0;
    case (key12)
        12'b001001001100: begin right_digit = 4'd6; right_valid = 1'b1; end
        12'b001001011010: begin right_digit = 4'd4; right_valid = 1'b1; end
        12'b001010001011: begin right_digit = 4'd8; right_valid = 1'b1; end
        12'b001010011001: begin right_digit = 4'd5; right_valid = 1'b1; end
        12'b001011001010: begin right_digit = 4'd7; right_valid = 1'b1; end
        12'b001100001001: begin right_digit = 4'd3; right_valid = 1'b1; end
        12'b010001010010: begin right_digit = 4'd2; right_valid = 1'b1; end
        12'b010010010001: begin right_digit = 4'd1; right_valid = 1'b1; end
        12'b011001001010: begin right_digit = 4'd9; right_valid = 1'b1; end
        12'b011010001001: begin right_digit = 4'd0; right_valid = 1'b1; end
        default: ;
    endcase
end

// ---- accumulated digits + which A/B table each left digit used ----
reg [2:0] elem_idx;
reg [2:0] digit_idx;
reg [5:0] parity_bits;
reg [23:0] left_digits;    // 6 x 4-bit, digit0 in bits[3:0]
reg [23:0] right_digits;   // 6 x 4-bit, digit0 (=check digit is right_digits[5]) in bits[3:0]

// ---- leading digit implied by the left group's A/B pattern ----
reg       leading_valid;
reg [3:0] leading_digit;
always @* begin
    leading_digit = 4'd0;
    leading_valid = 1'b0;
    // parity_bits[digit_idx] holds each left digit's A/B choice, digit0 at
    // the LSB -- so these literals list bit5(digit5)..bit0(digit0), i.e.
    // the LEFT_PATTERN string reversed before mapping A/B to 0/1 (caught
    // via simulation: the first version of this table assumed digit0 was
    // the MSB, matching how python-barcode prints the pattern string
    // left-to-right, which silently disagreed with how the hardware
    // register actually indexes -- see tb_ean13_decoder.v run notes).
    case (parity_bits)
        6'b000000: begin leading_digit = 4'd0; leading_valid = 1'b1; end  // AAAAAA
        6'b110100: begin leading_digit = 4'd1; leading_valid = 1'b1; end  // AABABB
        6'b101100: begin leading_digit = 4'd2; leading_valid = 1'b1; end  // AABBAB
        6'b011100: begin leading_digit = 4'd3; leading_valid = 1'b1; end  // AABBBA
        6'b110010: begin leading_digit = 4'd4; leading_valid = 1'b1; end  // ABAABB
        6'b100110: begin leading_digit = 4'd5; leading_valid = 1'b1; end  // ABBAAB
        6'b001110: begin leading_digit = 4'd6; leading_valid = 1'b1; end  // ABBBAA
        6'b101010: begin leading_digit = 4'd7; leading_valid = 1'b1; end  // ABABAB
        6'b011010: begin leading_digit = 4'd8; leading_valid = 1'b1; end  // ABABBA
        6'b010110: begin leading_digit = 4'd9; leading_valid = 1'b1; end  // ABBABA
        default: ;
    endcase
end

// ---- checksum (standard EAN-13 weighted mod-10 check) ----
function [3:0] mod10;
    input [7:0] v;
    reg [7:0] t;
    integer i;
    begin
        t = v;
        for (i = 0; i < 25; i = i + 1)
            if (t >= 8'd10) t = t - 8'd10;
        mod10 = t[3:0];
    end
endfunction

wire [3:0] l0 = left_digits[3:0],   l1 = left_digits[7:4],   l2 = left_digits[11:8];
wire [3:0] l3 = left_digits[15:12], l4 = left_digits[19:16], l5 = left_digits[23:20];
wire [3:0] r0 = right_digits[3:0],  r1 = right_digits[7:4],  r2 = right_digits[11:8];
wire [3:0] r3 = right_digits[15:12], r4 = right_digits[19:16], r5 = right_digits[23:20];

wire [7:0] wsum1 = leading_digit + l1 + l3 + l5 + r1 + r3;
wire [7:0] wsum3 = l0 + l2 + l4 + r0 + r2 + r4;
wire [9:0] wtotal = wsum1 + (wsum3 * 3);
wire [3:0] wmod   = mod10(wtotal[7:0]);
wire [3:0] check_expected = (wmod == 4'd0) ? 4'd0 : (4'd10 - wmod);
wire checksum_ok = (check_expected == r5);

localparam [2:0] S_HUNT     = 3'd0,
                  S_LEFT     = 3'd1,
                  S_MIDGUARD = 3'd2,
                  S_RIGHT    = 3'd3,
                  S_ENDGUARD = 3'd4;

reg [2:0] state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        run_color      <= 1'b0;
        run_len        <= 11'd0;
        run_active     <= 1'b0;
        X_est          <= 11'd0;
        hist_w1        <= 11'd0;
        hist_w2        <= 11'd0;
        run_seen_count <= 2'd0;
        mh0            <= 3'd0;
        mh1            <= 3'd0;
        mh2            <= 3'd0;
        elem_idx       <= 3'd0;
        digit_idx      <= 3'd0;
        parity_bits    <= 6'd0;
        left_digits    <= 24'd0;
        right_digits   <= 24'd0;
        state          <= S_HUNT;
        ean_valid      <= 1'b0;
        decoded_digits <= 52'd0;
    end
    else begin
        ean_valid <= 1'b0;

        if (frame_pulse) begin
            // each frame decoded from scratch, no cross-frame memory
            run_active     <= 1'b0;
            hist_w1        <= 11'd0;
            hist_w2        <= 11'd0;
            run_seen_count <= 2'd0;
            elem_idx       <= 3'd0;
            digit_idx      <= 3'd0;
            parity_bits    <= 6'd0;
            state          <= S_HUNT;
        end
        else if (scan_active) begin
            if (!run_active) begin
                run_color  <= is_bar;
                run_len    <= 11'd1;
                run_active <= 1'b1;
            end
            else if (new_run_break) begin
                case (state)
                    S_HUNT: begin
                        if (guard_match) begin
                            X_est       <= X_est_next;
                            state       <= S_LEFT;
                            elem_idx    <= 3'd0;
                            digit_idx   <= 3'd0;
                            parity_bits <= 6'd0;
                        end
                    end

                    S_LEFT: begin
                        case (elem_idx)
                            3'd0: mh0 <= n_now;
                            3'd1: mh1 <= n_now;
                            3'd2: mh2 <= n_now;
                            3'd3: begin
                                if (left_valid) begin
                                    left_digits[digit_idx*4 +: 4] <= left_digit;
                                    parity_bits[digit_idx]        <= left_setbit;
                                    if (digit_idx == 3'd5) begin
                                        state    <= S_MIDGUARD;
                                        elem_idx <= 3'd0;
                                    end
                                    else begin
                                        digit_idx <= digit_idx + 3'd1;
                                        elem_idx  <= 3'd0;
                                    end
                                end
                                else begin
                                    state <= S_HUNT;   // lookup miss -- abandon this attempt
                                end
                            end
                            default: ;
                        endcase
                        if (elem_idx != 3'd3) elem_idx <= elem_idx + 3'd1;
                    end

                    S_MIDGUARD: begin
                        if (elem_idx == 3'd4) begin
                            state     <= S_RIGHT;
                            elem_idx  <= 3'd0;
                            digit_idx <= 3'd0;
                        end
                        else elem_idx <= elem_idx + 3'd1;
                    end

                    S_RIGHT: begin
                        case (elem_idx)
                            3'd0: mh0 <= n_now;
                            3'd1: mh1 <= n_now;
                            3'd2: mh2 <= n_now;
                            3'd3: begin
                                if (right_valid) begin
                                    right_digits[digit_idx*4 +: 4] <= right_digit;
                                    if (digit_idx == 3'd5) begin
                                        state    <= S_ENDGUARD;
                                        elem_idx <= 3'd0;
                                    end
                                    else begin
                                        digit_idx <= digit_idx + 3'd1;
                                        elem_idx  <= 3'd0;
                                    end
                                end
                                else begin
                                    state <= S_HUNT;
                                end
                            end
                            default: ;
                        endcase
                        if (elem_idx != 3'd3) elem_idx <= elem_idx + 3'd1;
                    end

                    S_ENDGUARD: begin
                        if (elem_idx == 3'd2) begin
                            if (leading_valid && checksum_ok) begin
                                ean_valid      <= 1'b1;
                                decoded_digits <= {right_digits, left_digits, leading_digit};
                            end
                            state    <= S_HUNT;
                            elem_idx <= 3'd0;
                        end
                        else elem_idx <= elem_idx + 3'd1;
                    end

                    default: state <= S_HUNT;
                endcase

                hist_w2 <= hist_w1;
                hist_w1 <= run_len;
                if (run_seen_count != 2'd3) run_seen_count <= run_seen_count + 2'd1;

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
