// ov5640_reg_table.v -- OV5640 init register list, 480x272 output.
// Each entry packs {reg_addr[15:0], data[7:0]} into 24 bits.
// Note: output is actually YUV422/YUYV, not RGB565 -- see entries below (0x4300/0x501f).
module ov5640_reg_table (
    input      [8:0] addr,
    output reg [23:0] data,
    output     [8:0]  total
);

assign total = 9'd253;  // total number of register entries

always @(*) begin
    case (addr)
        // Software reset
        9'd0:   data = {16'h3103, 8'h11};
        9'd1:   data = {16'h3008, 8'h82};  // software reset
        // Clock and PLL
        9'd2:   data = {16'h3008, 8'h42};  // power down
        9'd3:   data = {16'h3103, 8'h03};
        9'd4:   data = {16'h3017, 8'hff};
        9'd5:   data = {16'h3018, 8'hff};
        9'd6:   data = {16'h3034, 8'h1a};  // MIPI 10-bit
        9'd7:   data = {16'h3035, 8'h11};  // PLL
        9'd8:   data = {16'h3036, 8'h46};  // PLL multiplier
        9'd9:   data = {16'h3037, 8'h13};  // PLL divider
        9'd10:  data = {16'h3108, 8'h01};
        9'd11:  data = {16'h3824, 8'h01};
        9'd12:  data = {16'h460c, 8'h20};
        // Output format: RGB565
        9'd13:  data = {16'h4300, 8'h30};  // YUV422 YUYV (was RGB565 0x61)
        9'd14:  data = {16'h501f, 8'h00};  // ISP YUV (was RGB 0x01)
        // DVP output enable
        9'd15:  data = {16'h3002, 8'h1c};
        9'd16:  data = {16'h3006, 8'hc3};
        // FREX / strobe
        // Horizontal mirror ON (0x3821 bit1+bit2 set, 0x07 vs 0x01) -- user
        // reported the live image looks mirrored; the sensor's raw readout
        // apparently comes out mirrored relative to the true scene (this is
        // common depending on how the module is physically mounted), so we
        // flip it back at the sensor via this register rather than leaving
        // it uncorrected. This affects BOTH the LCD preview and the BNN
        // classifier equally (they read the exact same pixel stream), which
        // matters because handwritten digits are not left-right symmetric --
        // an uncorrected mirror would feed bnn_core images it was never
        // trained on. NOT YET VISUALLY CONFIRMED on real hardware -- after
        // recompiling, check that text/handwriting held up to the camera
        // reads normally (not backwards) on the LCD; if it's backwards the
        // OTHER way now, revert this byte back to 0x01 (also update the
        // duplicate entry near the end of this table, see below).
        9'd17:  data = {16'h3821, 8'h07};  // horizontal mirror ON
        9'd18:  data = {16'h3820, 8'h41};  // vertical flip off (unchanged)
        // Timing and resolution: 480x272
        9'd19:  data = {16'h3800, 8'h00};  // x start H
        9'd20:  data = {16'h3801, 8'h00};  // x start L
        9'd21:  data = {16'h3802, 8'h00};  // y start H
        9'd22:  data = {16'h3803, 8'h04};  // y start L
        9'd23:  data = {16'h3804, 8'h0a};  // x end H
        9'd24:  data = {16'h3805, 8'h3f};  // x end L
        9'd25:  data = {16'h3806, 8'h07};  // y end H
        9'd26:  data = {16'h3807, 8'h9b};  // y end L
        9'd27:  data = {16'h3808, 8'h01};  // output width H  (480 = 0x01E0)
        9'd28:  data = {16'h3809, 8'he0};  // output width L
        9'd29:  data = {16'h380a, 8'h00};  // output height H (272 = 0x0110)
        9'd30:  data = {16'h380b, 8'hd0};  // output height L (272 = 0x0110) -- 0xD0
        9'd31:  data = {16'h380c, 8'h07};  // total H width H
        9'd32:  data = {16'h380d, 8'h68};  // total H width L
        9'd33:  data = {16'h380e, 8'h04};  // total V height H
        9'd34:  data = {16'h380f, 8'h46};  // total V height L
        9'd35:  data = {16'h3810, 8'h00};  // H offset H
        9'd36:  data = {16'h3811, 8'h10};  // H offset L
        9'd37:  data = {16'h3812, 8'h00};  // V offset H
        9'd38:  data = {16'h3813, 8'h06};  // V offset L
        9'd39:  data = {16'h3814, 8'h31};  // H subsample
        9'd40:  data = {16'h3815, 8'h31};  // V subsample
        9'd41:  data = {16'h3618, 8'h00};
        9'd42:  data = {16'h3612, 8'h29};
        9'd43:  data = {16'h3708, 8'h64};
        9'd44:  data = {16'h3709, 8'h52};
        9'd45:  data = {16'h370c, 8'h03};
        // AEC/AGC
        9'd46:  data = {16'h3a02, 8'h03};
        9'd47:  data = {16'h3a03, 8'hd8};
        9'd48:  data = {16'h3a08, 8'h01};
        9'd49:  data = {16'h3a09, 8'h27};
        9'd50:  data = {16'h3a0a, 8'h00};
        9'd51:  data = {16'h3a0b, 8'hf6};
        9'd52:  data = {16'h3a0e, 8'h03};
        9'd53:  data = {16'h3a0d, 8'h04};
        9'd54:  data = {16'h3a14, 8'h03};
        9'd55:  data = {16'h3a15, 8'hd8};
        // BLC
        9'd56:  data = {16'h4001, 8'h02};
        9'd57:  data = {16'h4004, 8'h02};
        // System control
        9'd58:  data = {16'h3000, 8'h00};
        9'd59:  data = {16'h3001, 8'h00};
        9'd60:  data = {16'h3002, 8'h00};
        9'd61:  data = {16'h3212, 8'ha0};
        9'd62:  data = {16'h3006, 8'hff};  // enable clocks
        9'd63:  data = {16'h302e, 8'h08};
        // AWB
        9'd64:  data = {16'h5180, 8'hff};
        9'd65:  data = {16'h5181, 8'hf2};
        9'd66:  data = {16'h5182, 8'h00};
        9'd67:  data = {16'h5183, 8'h14};
        9'd68:  data = {16'h5184, 8'h25};
        9'd69:  data = {16'h5185, 8'h24};
        9'd70:  data = {16'h5186, 8'h09};
        9'd71:  data = {16'h5187, 8'h09};
        9'd72:  data = {16'h5188, 8'h09};
        9'd73:  data = {16'h5189, 8'h75};
        9'd74:  data = {16'h518a, 8'h54};
        9'd75:  data = {16'h518b, 8'he0};
        9'd76:  data = {16'h518c, 8'hb2};
        9'd77:  data = {16'h518d, 8'h42};
        9'd78:  data = {16'h518e, 8'h3d};
        9'd79:  data = {16'h518f, 8'h56};
        9'd80:  data = {16'h5190, 8'h46};
        9'd81:  data = {16'h5191, 8'hf8};
        9'd82:  data = {16'h5192, 8'h04};
        9'd83:  data = {16'h5193, 8'h70};
        9'd84:  data = {16'h5194, 8'hf0};
        9'd85:  data = {16'h5195, 8'hf0};
        9'd86:  data = {16'h5196, 8'h03};
        9'd87:  data = {16'h5197, 8'h01};
        9'd88:  data = {16'h5198, 8'h04};
        9'd89:  data = {16'h5199, 8'h12};
        9'd90:  data = {16'h519a, 8'h04};
        9'd91:  data = {16'h519b, 8'h00};
        9'd92:  data = {16'h519c, 8'h06};
        9'd93:  data = {16'h519d, 8'h82};
        9'd94:  data = {16'h519e, 8'h38};
        // Color matrix
        9'd95:  data = {16'h5381, 8'h1e};
        9'd96:  data = {16'h5382, 8'h5b};
        9'd97:  data = {16'h5383, 8'h08};
        9'd98:  data = {16'h5384, 8'h0a};
        9'd99:  data = {16'h5385, 8'h7e};
        9'd100: data = {16'h5386, 8'h88};
        9'd101: data = {16'h5387, 8'h7c};
        9'd102: data = {16'h5388, 8'h6c};
        9'd103: data = {16'h5389, 8'h10};
        9'd104: data = {16'h538a, 8'h01};
        9'd105: data = {16'h538b, 8'h98};
        // CIP
        9'd106: data = {16'h5300, 8'h08};
        9'd107: data = {16'h5301, 8'h30};
        9'd108: data = {16'h5302, 8'h10};
        9'd109: data = {16'h5303, 8'h00};
        9'd110: data = {16'h5304, 8'h08};
        9'd111: data = {16'h5305, 8'h30};
        9'd112: data = {16'h5306, 8'h08};
        9'd113: data = {16'h5307, 8'h16};
        9'd114: data = {16'h5309, 8'h08};
        9'd115: data = {16'h530a, 8'h30};
        9'd116: data = {16'h530b, 8'h04};
        9'd117: data = {16'h530c, 8'h06};
        // Gamma
        9'd118: data = {16'h5480, 8'h01};
        9'd119: data = {16'h5481, 8'h08};
        9'd120: data = {16'h5482, 8'h14};
        9'd121: data = {16'h5483, 8'h28};
        9'd122: data = {16'h5484, 8'h51};
        9'd123: data = {16'h5485, 8'h65};
        9'd124: data = {16'h5486, 8'h71};
        9'd125: data = {16'h5487, 8'h7d};
        9'd126: data = {16'h5488, 8'h87};
        9'd127: data = {16'h5489, 8'h91};
        9'd128: data = {16'h548a, 8'h9a};
        9'd129: data = {16'h548b, 8'haa};
        9'd130: data = {16'h548c, 8'hb8};
        9'd131: data = {16'h548d, 8'hcd};
        9'd132: data = {16'h548e, 8'hdd};
        9'd133: data = {16'h548f, 8'hea};
        9'd134: data = {16'h5490, 8'h1d};
        // UV adjust
        9'd135: data = {16'h5580, 8'h06};
        9'd136: data = {16'h5583, 8'h40};
        9'd137: data = {16'h5584, 8'h40};  // saturation up
        9'd138: data = {16'h5589, 8'h10};
        9'd139: data = {16'h558a, 8'h00};
        9'd140: data = {16'h558b, 8'hf8};
        // Lens correction
        9'd141: data = {16'h5800, 8'h23};
        9'd142: data = {16'h5801, 8'h14};
        9'd143: data = {16'h5802, 8'h0f};
        9'd144: data = {16'h5803, 8'h0f};
        9'd145: data = {16'h5804, 8'h12};
        9'd146: data = {16'h5805, 8'h26};
        9'd147: data = {16'h5806, 8'h0c};
        9'd148: data = {16'h5807, 8'h08};
        9'd149: data = {16'h5808, 8'h05};
        9'd150: data = {16'h5809, 8'h05};
        9'd151: data = {16'h580a, 8'h08};
        9'd152: data = {16'h580b, 8'h0d};
        9'd153: data = {16'h580c, 8'h08};
        9'd154: data = {16'h580d, 8'h03};
        9'd155: data = {16'h580e, 8'h00};
        9'd156: data = {16'h580f, 8'h00};
        9'd157: data = {16'h5810, 8'h03};
        9'd158: data = {16'h5811, 8'h09};
        9'd159: data = {16'h5812, 8'h07};
        9'd160: data = {16'h5813, 8'h03};
        9'd161: data = {16'h5814, 8'h00};
        9'd162: data = {16'h5815, 8'h01};
        9'd163: data = {16'h5816, 8'h03};
        9'd164: data = {16'h5817, 8'h08};
        9'd165: data = {16'h5818, 8'h0d};
        9'd166: data = {16'h5819, 8'h08};
        9'd167: data = {16'h581a, 8'h05};
        9'd168: data = {16'h581b, 8'h06};
        9'd169: data = {16'h581c, 8'h08};
        9'd170: data = {16'h581d, 8'h0e};
        9'd171: data = {16'h581e, 8'h29};
        9'd172: data = {16'h581f, 8'h17};
        9'd173: data = {16'h5820, 8'h11};
        9'd174: data = {16'h5821, 8'h11};
        9'd175: data = {16'h5822, 8'h15};
        9'd176: data = {16'h5823, 8'h28};
        9'd177: data = {16'h5824, 8'h46};
        9'd178: data = {16'h5825, 8'h26};
        9'd179: data = {16'h5826, 8'h08};
        9'd180: data = {16'h5827, 8'h26};
        9'd181: data = {16'h5828, 8'h64};
        9'd182: data = {16'h5829, 8'h26};
        9'd183: data = {16'h582a, 8'h24};
        9'd184: data = {16'h582b, 8'h22};
        9'd185: data = {16'h582c, 8'h24};
        9'd186: data = {16'h582d, 8'h24};
        9'd187: data = {16'h582e, 8'h06};
        9'd188: data = {16'h582f, 8'h22};
        9'd189: data = {16'h5830, 8'h40};
        9'd190: data = {16'h5831, 8'h42};
        9'd191: data = {16'h5832, 8'h24};
        9'd192: data = {16'h5833, 8'h26};
        9'd193: data = {16'h5834, 8'h24};
        9'd194: data = {16'h5835, 8'h22};
        9'd195: data = {16'h5836, 8'h22};
        9'd196: data = {16'h5837, 8'h26};
        9'd197: data = {16'h5838, 8'h44};
        9'd198: data = {16'h5839, 8'h24};
        9'd199: data = {16'h583a, 8'h26};
        9'd200: data = {16'h583b, 8'h28};
        9'd201: data = {16'h583c, 8'h42};
        9'd202: data = {16'h583d, 8'hce};
        // AEC
        9'd203: data = {16'h5025, 8'h00};
        9'd204: data = {16'h3a0f, 8'h38};  // AEC target up
        9'd205: data = {16'h3a10, 8'h30};
        9'd206: data = {16'h3a1b, 8'h38};
        9'd207: data = {16'h3a1e, 8'h30};
        9'd208: data = {16'h3a11, 8'h70};
        9'd209: data = {16'h3a1f, 8'h18};
        // Timing fine-tune for 480x272
        9'd210: data = {16'h460b, 8'h35};
        9'd211: data = {16'h460c, 8'h22};
        9'd212: data = {16'h3824, 8'h01};
        9'd213: data = {16'h5001, 8'ha3};
        // Denoise
        9'd214: data = {16'h5308, 8'h25};
        9'd215: data = {16'h5304, 8'h08};
        // Sharpness
        9'd216: data = {16'h5302, 8'h10};
        9'd217: data = {16'h5303, 8'h00};
        // Output size: 480x272 (final)
        9'd218: data = {16'h3808, 8'h01};  // width  H = 0x01
        9'd219: data = {16'h3809, 8'he0};  // width  L = 0xE0 → 480
        9'd220: data = {16'h380a, 8'h01};  // height H = 0x01
        9'd221: data = {16'h380b, 8'h10};  // height L = 0x10 → 272
        // PCLK polarity
        9'd222: data = {16'h4740, 8'h21};
        // VSYNC / HREF polarity
        9'd223: data = {16'h4741, 8'h00};
        // DVP PCLK divider
        9'd224: data = {16'h3824, 8'h02};
        // Mirror ON / flip off -- this is the FINAL write to these two
        // registers (applied after the output-window setup above, and
        // right before power-on below), so this is the value that actually
        // sticks; keep in sync with the 0x3821 change near entry 17 above.
        9'd225: data = {16'h3821, 8'h07};
        9'd226: data = {16'h3820, 8'h41};
        // Power on
        9'd227: data = {16'h3008, 8'h02};  // wake up from power down
        // Saturation
        9'd228: data = {16'h5001, 8'ha3};
        9'd229: data = {16'h5580, 8'h06};
        9'd230: data = {16'h5583, 8'h40};
        9'd231: data = {16'h5584, 8'h40};  // saturation up
        // Brightness
        9'd232: data = {16'h5587, 8'h00};
        9'd233: data = {16'h5588, 8'h01};
        // Contrast
        9'd234: data = {16'h5585, 8'h20};
        9'd235: data = {16'h5586, 8'h20};
        // Hue
        9'd236: data = {16'h5589, 8'h10};
        9'd237: data = {16'h558a, 8'h00};
        9'd238: data = {16'h558b, 8'hef};
        // Special effect: none
        9'd239: data = {16'h5580, 8'h06};
        // Sharpness fine
        9'd240: data = {16'h5308, 8'h65};
        9'd241: data = {16'h5302, 8'h20};
        // Exposure
        9'd242: data = {16'h3a00, 8'h78};
        // Zoom disable
        9'd243: data = {16'h6900, 8'h00};
        9'd244: data = {16'h6901, 8'h00};
        // Light mode: auto
        9'd245: data = {16'h3212, 8'h03};
        9'd246: data = {16'h3212, 8'h13};
        9'd247: data = {16'h3212, 8'ha3};
        // Test pattern off
        9'd248: data = {16'h503d, 8'h00};
        // Final enable
        9'd249: data = {16'h3008, 8'h02};
        9'd250: data = {16'h3035, 8'h21};
        9'd251: data = {16'h3036, 8'h46};
        9'd252: data = {16'h5000, 8'ha7};  // LENC + gamma + BPC/WPC enable

        default: data = {16'h0000, 8'h00};
    endcase
end

endmodule
