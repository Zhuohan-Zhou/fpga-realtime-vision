module roi_binarize_28x28 #(
    parameter [10:0] ROI_X0  = 11'd128,
    parameter [10:0] ROI_Y0  = 11'd24,
    parameter [7:0]  THRESH  = 8'd100   // y8 < THRESH => "dark" (ink stroke)
)(
    input             clk,          // clk_9m
    input             rst_n,        // sys_rst_n
    input             de,           // lcd_de_w
    input             frame_pulse,  // lcd_frame_pulse
    input      [7:0]  y8,           // disp_y
    input      [10:0] pixel_x,      // pixel_x_w
    input      [10:0] pixel_y,      // pixel_y_w

    output reg         img_valid,   // 1-cycle pulse: img_out is a fresh, complete frame
    output     [783:0] img_out,     
    output reg [15:0]  ink_count    
);

wire in_roi_x = (pixel_x >= ROI_X0) && (pixel_x < ROI_X0 + 11'd224);
wire in_roi_y = (pixel_y >= ROI_Y0) && (pixel_y < ROI_Y0 + 11'd224);
wire hit      = de && in_roi_x && in_roi_y;

// Constant-offset subtract + fixed >>3 -- pure wiring, not a real divider.
wire [4:0] bx = (pixel_x - ROI_X0) >> 3;   // 0-27
wire [4:0] by = (pixel_y - ROI_Y0) >> 3;   // 0-27
wire       dark = (y8 < THRESH);

reg [27:0] img_mem [0:27];
reg [27:0] accum_row;
reg [4:0]  by_reg;
reg        row_active;
reg [15:0] ink_run;   // running dark-pixel count for the frame currently being built

// Combinational "what accum_row becomes" helpers, same next-value idiom
// used in bnn_core.v's c1_acc_next/etc to avoid same-cycle stale reads.
reg [27:0] new_row_seed;
always @* begin
    new_row_seed = 28'd0;
    new_row_seed[bx] = dark;
end

reg [27:0] cont_row_next;
always @* begin
    cont_row_next = accum_row;
    cont_row_next[bx] = accum_row[bx] | dark;
end

integer k;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum_row  <= 28'd0;
        by_reg     <= 5'd0;
        row_active <= 1'b0;
        img_valid  <= 1'b0;
        ink_run    <= 16'd0;
        ink_count  <= 16'd0;
        for (k = 0; k < 28; k = k + 1)
            img_mem[k] <= 28'd0;
    end
    else begin
        img_valid <= 1'b0;

        if (hit) begin
            if (!row_active) begin
                by_reg     <= by;
                row_active <= 1'b1;
                accum_row  <= new_row_seed;
                ink_run    <= dark ? 16'd1 : 16'd0;
            end
            else if (by != by_reg) begin
                
                img_mem[by_reg] <= accum_row;
                by_reg          <= by;
                accum_row       <= new_row_seed;
                ink_run         <= ink_run + (dark ? 16'd1 : 16'd0);
            end
            else begin
                accum_row <= cont_row_next;
                ink_run   <= ink_run + (dark ? 16'd1 : 16'd0);
            end
        end

        if (frame_pulse) begin
            if (row_active)
                img_mem[by_reg] <= accum_row;   // flush the last row
            row_active <= 1'b0;
            img_valid  <= 1'b1;
            ink_count  <= ink_run;   // latch this frame's ink count, holds until the next
        end
    end
end

assign img_out = {img_mem[27], img_mem[26], img_mem[25], img_mem[24],
                   img_mem[23], img_mem[22], img_mem[21], img_mem[20],
                   img_mem[19], img_mem[18], img_mem[17], img_mem[16],
                   img_mem[15], img_mem[14], img_mem[13], img_mem[12],
                   img_mem[11], img_mem[10], img_mem[9],  img_mem[8],
                   img_mem[7],  img_mem[6],  img_mem[5],  img_mem[4],
                   img_mem[3],  img_mem[2],  img_mem[1],  img_mem[0]};

endmodule
