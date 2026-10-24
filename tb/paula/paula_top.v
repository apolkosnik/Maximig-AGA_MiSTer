// Unit-bench wrapper: the real paula (interrupts, uart, audio, floppy) and the
// real agnus_audiodma, with a 128 KB chip RAM array and a horizontal counter.
// The C++ driver writes custom registers on cycles that are not DMA slots.
module paula_top
(
	input         clk,
	input         reset,
	input   [8:1] cpu_reg,       // register address of a CPU write/read ($1FE = none)
	input  [15:0] cpu_data,
	output [15:0] rd_data,       // paula's data_out for cpu_reg
	input         rxd,
	output        txd,
	output        dma,           // audio DMA uses this slot
	output  [8:0] hpos_o,
	output [20:1] dma_addr,
	output [15:0] dma_data,
	output  [3:0] dmas_o,        // Paula's dmas lines as latched at strhor
	output  [2:0] _ipl,
	output [14:0] intreq_o,
	output [14:0] intena_o,
	output  [3:0] audint_o,
	output  [7:0] sample0,
	output  [2:0] state0,
	output [15:0] lencnt0,
	output        silence0,
	output [14:0] ldata,
	input   [8:1] ram_wa,        // unused
	input         ram_we,
	input  [16:1] ram_waddr,
	input  [15:0] ram_wdata
);

reg [8:0] hpos = 9'd0;
always @(posedge clk)
	hpos <= (hpos == 9'd453) ? 9'd0 : hpos + 9'd1;
assign hpos_o = hpos;
wire cck    = hpos[0];
wire strhor = (hpos == 9'd13);   // agnus.v strhor_paula: hpos==(6*2+1)

reg [15:0] ram [0:65535];
always @(posedge clk) if (ram_we) ram[ram_waddr] <= ram_wdata;

wire [3:0] audio_dmal, audio_dmas;
wire [8:1] reg_address_aud;
wire [20:1] address_out;
agnus_audiodma aud1
(
	.clk(clk), .clk7_en(1'b1), .dma(dma),
	.audio_dmal(audio_dmal), .audio_dmas(audio_dmas),
	.hpos(hpos), .reg_address_in(cpu_reg), .reg_address_out(reg_address_aud),
	.data_in(cpu_data), .address_out(address_out)
);
assign dma_addr = address_out;
assign dma_data = ram[address_out[16:1]];
assign dmas_o   = audio_dmas;

wire [8:1] reg_address = dma ? reg_address_aud : cpu_reg;
wire [15:0] data_in    = dma ? dma_data : cpu_data;

wire [15:0] data_out;
assign rd_data = data_out;

paula p
(
	.clk(clk), .clk7_en(1'b1), .clk7n_en(1'b1), .cck(cck), .reset(reset),
	.reg_address_in(reg_address), .data_in(data_in), .data_out(data_out),
	.txd(txd), .rxd(rxd), .ntsc(1'b0), .sof(1'b0), .strhor(strhor),
	.vblint(1'b0), .int2(1'b0), .int3(1'b0), .int6(1'b0), ._ipl(_ipl),
	.audio_dmal(audio_dmal), .audio_dmas(audio_dmas), .disk_dmal(), .disk_dmas(),
	._step(1'b1), .direc(1'b1), ._sel(4'b1111), .side(1'b1), ._motor(1'b1),
	._track0(), ._change(), ._ready(), ._wprot(), .index(), .fdd_led(),
	.IO_ENA(1'b0), .IO_STROBE(1'b0), .IO_WAIT(), .IO_DIN(16'h0), .IO_DOUT(),
	.ldata(ldata), .rdata(), .ldata_okk(), .rdata_okk(),
	.floppy_drives(2'b00), .floppy_zero_active(1'b0), .floppy_ext_drive(12'h0),
	.floppy_speed_allowed(1'b0), .floppy_speed(), .enable_mister_floppy(1'b0),
	.trackdisp(), .secdisp(), .floppy_fwr(), .floppy_frd(),
	.USER_IN(7'h0), .USER_OUT(), .mister_floppy_status(), .drive_snd()
);

assign intreq_o = p.pi1.intreq;
assign intena_o = p.pi1.intena;
assign audint_o = p.audint;
assign sample0  = p.ad1.sample0;
assign state0   = p.ad1.ach0.audio_state;
assign lencnt0  = p.ad1.ach0.lencnt;
assign silence0 = p.ad1.ach0.silence;

endmodule
