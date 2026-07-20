// captures OV5640 DVP bus (PCLK/HREF/VSYNC/D[7:0]) and
// assembles 16-bit pixels. Outputs pixel_data/pixel_valid/frame_vsync.
module dvp_capture (
    // DVP interface from OV5640
    input        pclk,          // pixel clock from OV5640  (PIN_G1)
    input        href,          // horizontal reference      (PIN_K1)
    input        vsync,         // vertical sync             (PIN_F2)
    input  [7:0] d,             // pixel data bus            (PIN_J2~L2)

    // System reset
    input        rst_n,

    // Pixel output
    output reg [15:0] pixel_data,   // RGB565 pixel
    output reg        pixel_valid,  // high for one pclk when pixel ready
    output reg        frame_vsync   // pulses high at start of each frame
);

// VSYNC/HREF are already sync to PCLK, just register them for clean edges
reg vsync_r1, vsync_r2;
reg href_r;
reg [7:0] d_r1;   // register data one cycle to align with href_r

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        vsync_r1 <= 1'b0;
        vsync_r2 <= 1'b0;
        href_r   <= 1'b0;
        d_r1     <= 8'd0;
    end
    else begin
        vsync_r1 <= vsync;
        vsync_r2 <= vsync_r1;
        href_r   <= href;
        d_r1     <= d;
    end
end

// VSYNC falling edge = start of new frame
wire vsync_fall = vsync_r2 & ~vsync_r1;

// Byte counter: track high/low byte of each RGB565 pixel
reg byte_cnt;   // 0 = first byte (high), 1 = second byte (low)
reg [7:0] d_r;  // latch first byte

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        byte_cnt    <= 1'b0;
        d_r         <= 8'd0;
        pixel_data  <= 16'd0;
        pixel_valid <= 1'b0;
        frame_vsync <= 1'b0;
    end
    else begin
        // Default: clear pulse signals
        pixel_valid <= 1'b0;
        frame_vsync <= 1'b0;

        // Frame start pulse
        if (vsync_fall)
            frame_vsync <= 1'b1;

        // Reset byte counter at start of each line or frame
        if (!href_r)
            byte_cnt <= 1'b0;

        // Capture pixel data when HREF is high
        if (href_r) begin
            if (byte_cnt == 1'b0) begin
                // First byte: latch high byte, wait for second
                d_r      <= d_r1;           // use aligned data
                byte_cnt <= 1'b1;
            end
            else begin
                // Second byte: combine with first to form full pixel
                pixel_data  <= {d_r, d_r1}; // {first byte, second byte}
                pixel_valid <= 1'b1;
                byte_cnt    <= 1'b0;
            end
        end
    end
end

endmodule