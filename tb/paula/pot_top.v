// Unit-bench wrapper: the real userio (POTGO, POT0DAT/POT1DAT, POTINP)
module pot_top
(
	input         clk,
	input         reset,
	input   [8:1] reg_addr,
	input  [15:0] din,
	output [15:0] dout,
	input         line,          // one pulse per scanline (pot_cnt_en)
	input  [15:0] joy_ana1,
	input  [15:0] joy_ana2,
	input  [15:0] joy1,
	input  [15:0] joy2
);
userio u
(
	.clk(clk), .reset(reset), .clk7_en(1'b1), .reg_address_in(reg_addr),
	.data_in(din), .data_out(dout), .pot_cnt_en(line),
	._fire0(), ._fire1(), ._fire0_dat(1'b1), ._fire1_dat(1'b1),
	._joy1(joy1), ._joy2(joy2), .joy_ana1(joy_ana1), .joy_ana2(joy_ana2),
	.mouse_btn(3'b000), .kms_level(1'b0), .kbd_mouse_type(2'b00), .kbd_mouse_data(8'h00),
	.aud_mix(), .IO_ENA(1'b0), .IO_STROBE(1'b0), .IO_WAIT(), .IO_DIN(16'h0),
	.memory_config(), .chipset_config(), .floppy_config(), .floppy_ext_drive(),
	.user_port_mode(), .scanline(), .ar(), .blver(), .ide_config(), .cpu_config(),
	.cache_config(), .bootrom(), .usrrst(), .cpurst(), .cpuhlt(), .host_cs(),
	.host_adr(), .host_we(), .host_bs(), .host_wdat(), .host_rdat(16'h0), .host_ack(1'b0)
);
endmodule
