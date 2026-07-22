module display_mode_select (
    input        clk,      // clk_9m
    input        rst_n,

    input        key1_n,   // Sobel
    input        key2_n,   // binarize
    input        key3_n,   // centroid tracking

    output reg [1:0] mode
);

localparam [1:0] MODE_TRACKING = 2'd0,
                  MODE_SOBEL    = 2'd1,
                  MODE_BINARIZE = 2'd2;

wire p1, p2, p3;

button_debounce u_db1 (.clk(clk), .rst_n(rst_n), .raw_n(key1_n), .pressed(p1));
button_debounce u_db2 (.clk(clk), .rst_n(rst_n), .raw_n(key2_n), .pressed(p2));
button_debounce u_db3 (.clk(clk), .rst_n(rst_n), .raw_n(key3_n), .pressed(p3));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        mode <= MODE_TRACKING;
    else if (p1)
        mode <= MODE_SOBEL;
    else if (p2)
        mode <= MODE_BINARIZE;
    else if (p3)
        mode <= MODE_TRACKING;
end

endmodule
