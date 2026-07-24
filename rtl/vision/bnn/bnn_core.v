// 28x28 binary BNN, trained by scripts/train_bnn_v2.py.
// The arithmetic is deliberately serial: one XNOR/popcount contribution per
// clock.  This preserves the 4 -> 8 -> 200 -> 10 model while avoiding a large
// spatially-unrolled combinational network on the EP4CE10.
module bnn_core(
    input clk, input rst_n, input start,
    input [783:0] image_in,
    output reg done, output reg [3:0] digit_out
);
localparam [8:0] W10=9'b010110111, W11=9'b110001001, W12=9'b000110000, W13=9'b001110100;
localparam [35:0] W20=36'b000011111110111000010100010011100110;
localparam [35:0] W21=36'b001011001101100011101100110011010011;
localparam [35:0] W22=36'b100000101011110101110100010100111010;
localparam [35:0] W23=36'b011111011000110111101000101001101101;
localparam [35:0] W24=36'b100101001010111001011000000100110110;
localparam [35:0] W25=36'b011001110111010110100110101011010001;
localparam [35:0] W26=36'b111001000000111101000110110100010010;
localparam [35:0] W27=36'b110100100011010100010011101110011110;
localparam [199:0] WD0=200'b00111010001100111011011101011111100010110001110011101100101010110101111100110010001111100111001011110111011111000101101111001101111001100010000101010111000101110001110001110001101100010001100010000101;
localparam [199:0] WD1=200'b00000001000010000101110010001100001001011100100011000101101101001011101000000001000001010000101000000011110111001111101000100110110010011101100000100111110111010111100101011000111011101110111101010011;
localparam [199:0] WD2=200'b11110000000111111101110011001011010011010101110010101101100101010110010001111110100000001011101110111110010111101111111110010110000000111100001111111110111011100000000010111110111101111110010011100110;
localparam [199:0] WD3=200'b11010001000100110111111110010001000110000101101010010111011101101011100110001110101110011110011110111110000111010110001111001110100000010100101111000110110011000011101110100010011101110100111101101001;
localparam [199:0] WD4=200'b00001010101111100000001010101010001000101011011000000101010111110110000110001001010111111111111000000111111111101101110100000101100100110000011111010110010100001100111111001101111100100001011111011101;
localparam [199:0] WD5=200'b00011010010100111110110110001001001010010111011010100011000110011011110110101011001001110000001111110111111101100101011010011010011001110011011110100010010110111111111110010001011000111101111111011111;
localparam [199:0] WD6=200'b00000010010111101011010000011001101110010001010011010011001110110010000000111110000001101101111011110011111110111101111000001110001100111011011101100000000100011000011001111100000100011001011001001111;
localparam [199:0] WD7=200'b11111100000001100110011000100011110000110001110011001110001111000111000111000000111111001100010001000010011111100110111110010010101011011010000101100110001111000111110010100000111001101111011100011001;
localparam [199:0] WD8=200'b01111110010110011000011100001010000010011100100000111111000110111010000101011111011111011101100011110111011011110111101011000010010011011110101110100110000110001100101110110011011000110110111001101000;
localparam [199:0] WD9=200'b00111010111110000100000010101000100001000111000010000101011111100110000010010110111101111100010000000110011111101011100100010111100001001100010001010100011001101100111101000000111100111011011101101101;

localparam [2:0] S_IDLE=3'd0, S_LOAD=3'd1, S_C1=3'd2,
                 S_C2=3'd3, S_DENSE=3'd4, S_DONE=3'd5;

reg [2:0] state;
reg [2:0] co, ci, fch;
reg [3:0] dk;
reg [4:0] row, col, load_row;
reg [1:0] ky, kx;
reg [5:0] match_count;
reg [7:0] best_count;
reg [3:0] best_digit;

// Only the feature maps needed by the next layer are stored.  Pooling is
// performed while the preceding convolution is generated, so a1/a2 full
// feature maps do not consume flip-flops or routing.
reg [27:0] img_mem [0:27];
reg [51:0] p1_rows [0:12];   // four 13-bit channels per row
reg [39:0] p2_rows [0:4];    // eight 5-bit channels per row
reg [12:0] pool1_top;
reg [4:0]  pool2_top;
reg        c1_prev, c2_prev;

function w1bit;
    input [2:0] f;
    input [3:0] n;
    reg [8:0] w;
    begin
        case (f)
            0: w=W10; 1: w=W11; 2: w=W12; default: w=W13;
        endcase
        w1bit = w[8-n];
    end
endfunction

function w2bit;
    input [2:0] f;
    input [5:0] n;
    reg [35:0] w;
    begin
        case (f)
            0:w=W20; 1:w=W21; 2:w=W22; 3:w=W23;
            4:w=W24; 5:w=W25; 6:w=W26; default:w=W27;
        endcase
        w2bit = w[35-n];
    end
endfunction

function wdbit;
    input [3:0] f;
    input [7:0] n;
    reg [199:0] w;
    begin
        case (f)
            0:w=WD0; 1:w=WD1; 2:w=WD2; 3:w=WD3; 4:w=WD4;
            5:w=WD5; 6:w=WD6; 7:w=WD7; 8:w=WD8; default:w=WD9;
        endcase
        wdbit = w[199-n];
    end
endfunction

wire c1_match = (img_mem[row + ky][col + kx] == w1bit(co, ky*3 + kx));
wire c2_match = (p1_rows[row + ky][ci*13 + col + kx] ==
                 w2bit(co, ci*9 + ky*3 + kx));
wire dense_match = (p2_rows[row][fch*5 + col] ==
                    wdbit(dk, fch*25 + row*5 + col));
wire c1_out = (match_count + c1_match >= 6'd5);
wire c2_out = (match_count + c2_match >= ((co == 3) ? 6'd18 : 6'd19));
wire [7:0] dense_total = match_count + dense_match;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_IDLE;
        done      <= 1'b0;
        digit_out <= 4'd0;
    end
    else begin
        done <= 1'b0;
        case (state)
            S_IDLE: begin
                if (start) begin
                    load_row <= 5'd0;
                    state    <= S_LOAD;
                end
            end

            S_LOAD: begin
                case (load_row)
                    0:img_mem[0]<=image_in[27:0];       1:img_mem[1]<=image_in[55:28];
                    2:img_mem[2]<=image_in[83:56];      3:img_mem[3]<=image_in[111:84];
                    4:img_mem[4]<=image_in[139:112];    5:img_mem[5]<=image_in[167:140];
                    6:img_mem[6]<=image_in[195:168];    7:img_mem[7]<=image_in[223:196];
                    8:img_mem[8]<=image_in[251:224];    9:img_mem[9]<=image_in[279:252];
                    10:img_mem[10]<=image_in[307:280]; 11:img_mem[11]<=image_in[335:308];
                    12:img_mem[12]<=image_in[363:336]; 13:img_mem[13]<=image_in[391:364];
                    14:img_mem[14]<=image_in[419:392]; 15:img_mem[15]<=image_in[447:420];
                    16:img_mem[16]<=image_in[475:448]; 17:img_mem[17]<=image_in[503:476];
                    18:img_mem[18]<=image_in[531:504]; 19:img_mem[19]<=image_in[559:532];
                    20:img_mem[20]<=image_in[587:560]; 21:img_mem[21]<=image_in[615:588];
                    22:img_mem[22]<=image_in[643:616]; 23:img_mem[23]<=image_in[671:644];
                    24:img_mem[24]<=image_in[699:672]; 25:img_mem[25]<=image_in[727:700];
                    26:img_mem[26]<=image_in[755:728]; default:img_mem[27]<=image_in[783:756];
                endcase
                if (load_row == 5'd27) begin
                    co <= 3'd0; row <= 5'd0; col <= 5'd0;
                    ky <= 2'd0; kx <= 2'd0; match_count <= 6'd0;
                    state <= S_C1;
                end
                else load_row <= load_row + 5'd1;
            end

            // Conv1 (3x3x1 -> 4) and pool1.  c1_prev/pool1_top retain only
            // the two rows needed to form a 2x2 max-pool result.
            S_C1: begin
                if ((ky == 2) && (kx == 2)) begin
                    match_count <= 6'd0;
                    c1_prev <= c1_out;
                    if (col[0]) begin
                        if (!row[0])
                            pool1_top[col[4:1]] <= c1_prev | c1_out;
                        else
                            p1_rows[row[4:1]][co*13 + col[4:1]] <=
                                pool1_top[col[4:1]] | c1_prev | c1_out;
                    end
                    ky <= 2'd0;
                    kx <= 2'd0;
                    if (col == 5'd25) begin
                        col <= 5'd0;
                        if (row == 5'd25) begin
                            row <= 5'd0;
                            if (co == 3) begin
                                co <= 3'd0; ci <= 3'd0;
                                state <= S_C2;
                            end
                            else co <= co + 3'd1;
                        end
                        else row <= row + 5'd1;
                    end
                    else col <= col + 5'd1;
                end
                else begin
                    match_count <= match_count + c1_match;
                    if (kx == 2) begin
                        kx <= 2'd0;
                        ky <= ky + 2'd1;
                    end
                    else kx <= kx + 2'd1;
                end
            end

            // Conv2 (3x3x4 -> 8) and pool2, again retaining just one pool row.
            S_C2: begin
                if ((ci == 3) && (ky == 2) && (kx == 2)) begin
                    match_count <= 6'd0;
                    c2_prev <= c2_out;
                    if ((row < 5'd10) && (col < 5'd10) && col[0]) begin
                        if (!row[0])
                            pool2_top[col[3:1]] <= c2_prev | c2_out;
                        else
                            p2_rows[row[3:1]][co*5 + col[3:1]] <=
                                pool2_top[col[3:1]] | c2_prev | c2_out;
                    end
                    ci <= 3'd0;
                    ky <= 2'd0;
                    kx <= 2'd0;
                    if (col == 5'd10) begin
                        col <= 5'd0;
                        if (row == 5'd10) begin
                            row <= 5'd0;
                            if (co == 3'd7) begin
                                dk <= 4'd0; fch <= 3'd0;
                                match_count <= 6'd0;
                                best_count <= 8'd0;
                                best_digit <= 4'd0;
                                state <= S_DENSE;
                            end
                            else co <= co + 3'd1;
                        end
                        else row <= row + 5'd1;
                    end
                    else col <= col + 5'd1;
                end
                else begin
                    match_count <= match_count + c2_match;
                    if (kx == 2) begin
                        kx <= 2'd0;
                        if (ky == 2) begin
                            ky <= 2'd0;
                            if (ci == 3)
                                ci <= 3'd0;
                            else
                                ci <= ci + 3'd1;
                        end
                        else ky <= ky + 2'd1;
                    end
                    else kx <= kx + 2'd1;
                end
            end

            S_DENSE: begin
                if ((fch == 3'd7) && (row == 5'd4) && (col == 5'd4)) begin
                    if (dense_total > best_count) begin
                        best_count <= dense_total;
                        best_digit <= dk;
                    end
                    match_count <= 6'd0;
                    fch <= 3'd0;
                    row <= 5'd0;
                    col <= 5'd0;
                    if (dk == 4'd9)
                        state <= S_DONE;
                    else
                        dk <= dk + 4'd1;
                end
                else begin
                    match_count <= dense_total;
                    if (col == 5'd4) begin
                        col <= 5'd0;
                        if (row == 5'd4) begin
                            row <= 5'd0;
                            if (fch == 3'd7)
                                fch <= 3'd0;
                            else
                                fch <= fch + 3'd1;
                        end
                        else row <= row + 5'd1;
                    end
                    else col <= col + 5'd1;
                end
            end

            S_DONE: begin
                digit_out <= best_digit;
                done <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end
endmodule
