// Unit bench: the real Agnus (rtl/minimig/agnus.v and its submodules) with
// the real amiga_clk clock-enable generator and a 2 MB chip RAM model.
// The C++ driver acts as the CPU (register accesses in free CPU slots) and
// as Paula (DMAL requests).
module tb_agnus (
	input  wire        clk,
	input  wire        reset_n,
	input  wire        reset,
	input  wire        ntsc,
	// CPU register port (driven by C++)
	input  wire        aen,
	input  wire        rd,
	input  wire        hwr,
	input  wire        lwr,
	input  wire [8:1]  cpu_addr,
	input  wire [15:0] cpu_wdata,
	output wire [15:0] cpu_rdata,
	// Paula
	input  wire [3:0]  audio_dmal,
	input  wire [3:0]  audio_dmas,
	input  wire        disk_dmal,
	input  wire        disk_dmas,
	input  wire        bls,
	// memory loader
	input  wire        mem_we,
	input  wire [20:1] mem_addr,
	input  wire [15:0] mem_wdata,
	// observation
	output wire        clk7_en,
	output wire        cck,
	output wire        dbr,
	output wire        dbwe,
	output wire        cpu_custom,
	output wire [20:1] dma_addr,
	output wire [8:1]  reg_addr,
	output wire [8:0]  hpos,
	output wire [10:0] vpos,
	output wire        vbl_int,
	output wire        sof,
	output wire        int3,
	output wire        bitplane_dma,
	output wire [15:0] bus_data,
	output wire        _hsync,
	output wire        _vsync
);

wire clk7n_en, c1, c3;
wire [9:0] eclk;
amiga_clk CLK (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
	.cck(cck), .eclk(eclk), .reset_n(reset_n));

reg [15:0] mem [0:1048575];
always @(posedge clk) begin
	if (mem_we) mem[mem_addr] <= mem_wdata;
	else if (clk7_en && dbr && dbwe) mem[dma_addr] <= agnus_dout;
end

wire [15:0] agnus_dout;
// bus data: a DMA read drives chip RAM data, a DMA write Agnus' data (blitter D),
// otherwise the CPU's write data
assign bus_data = dbr ? (dbwe ? agnus_dout : mem[dma_addr]) : (rd ? 16'hFFFF : cpu_wdata);
assign cpu_rdata = agnus_dout;

wire hde, sol, lace, field1, _csync, hblank, vblank, strhor_denise, strhor_paula, harddis, varbeamen;
wire bitplane_fetch_phase, bitplane_fetch_phase_valid, bitplane_fetch_unit_start, dmald;
wire [8:0] htotal;

agnus AGNUS1 (
	.clk(clk), .clk7_en(clk7_en), .cck(cck), .reset(reset),
	.aen(aen), .rd(rd), .hwr(hwr), .lwr(lwr),
	.data_in(bus_data), .data_out(agnus_dout), .address_in(cpu_addr),
	.address_out(dma_addr), .reg_address_out(reg_addr),
	.bitplane_dma(bitplane_dma), .bitplane_fetch_phase(bitplane_fetch_phase),
	.bitplane_fetch_phase_valid(bitplane_fetch_phase_valid),
	.bitplane_fetch_unit_start(bitplane_fetch_unit_start),
	.cpu_custom(cpu_custom), .dbr(dbr), .dmald(dmald), .dbwe(dbwe),
	._hsync(_hsync), ._vsync(_vsync), ._csync(_csync), .field1(field1), .lace(lace),
	.hblank(hblank), .vblank(vblank), .hde(hde), .sol(sol), .sof(sof), .vbl_int(vbl_int),
	.strhor_denise(strhor_denise), .strhor_paula(strhor_paula), .htotal(htotal),
	.harddis(harddis), .varbeamen(varbeamen), .int3(int3),
	.audio_dmal(audio_dmal), .audio_dmas(audio_dmas), .disk_dmal(disk_dmal), .disk_dmas(disk_dmas),
	.bls(bls), .ntsc(ntsc), .a1k(1'b0), .ecs(1'b1), .aga(1'b1), .floppy_speed(1'b0));

assign hpos = AGNUS1.hpos;
assign vpos = AGNUS1.vpos;
endmodule
