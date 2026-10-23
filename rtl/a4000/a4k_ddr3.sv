//============================================================================
//  a4k_ddr3: the core's DDR3 port
//
//  Three users share the MiSTer DDRAM interface (64-bit Avalon, word
//  address = byte address / 8):
//
//    m0  the motherboard (a4k_lbus): Zorro III RAM, the RTG framebuffer
//        and the HPS share window -- a read is a 16-byte line (a burst of
//        two), a write one long word with its byte enables
//    m1  mem2: the A2065 card's mailbox and board RAM, and the drive sound
//        samples, already merged (a2065_ddram_arbiter), as in Minimig
//
//  m0 has priority (Minimig's order: the CPU's memory must not wait on the
//  network card).  Memory is in the Amiga's byte order: byte address N of
//  the board is DDR3 byte 0x20000000 + offset + N, so the ARM sees the RTG
//  framebuffer and the share window as the Amiga does.  The motherboard
//  side is big-endian (D31-D24 the byte at offset 0).
//============================================================================

module a4k_ddr3
(
	input             clk,
	input             reset,

	// m0: toggle handshake from a4k_lbus
	input             cpu_req,
	output reg        cpu_ack,
	input      [28:2] cpu_addr,      // byte offset from 0x20000000
	input             cpu_we,
	input       [3:0] cpu_be,
	input      [31:0] cpu_wdata,
	output reg[127:0] cpu_rdata,     // the line at cpu_addr[28:4]

	// m1: Avalon slave for the merged A2065 / drive sound master
	input      [28:0] mem2_address,
	input       [7:0] mem2_burstcount,
	input             mem2_read,
	output     [63:0] mem2_readdata,
	output            mem2_readdatavalid,
	input      [63:0] mem2_writedata,
	input       [7:0] mem2_byteenable,
	input             mem2_write,
	output            mem2_waitrequest,

	// the MiSTer DDR3 port
	output            DDRAM_CLK,
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output            DDRAM_RD,
	output     [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE,
	output            DDRAM_WE
);

assign DDRAM_CLK = clk;

function automatic [31:0] rev32(input [31:0] w);
	rev32 = {w[7:0], w[15:8], w[23:16], w[31:24]};
endfunction

// m0 as an Avalon master
reg  [28:0] m0_address;
reg   [7:0] m0_burstcount;
reg         m0_read, m0_write;
reg  [63:0] m0_writedata;
reg   [7:0] m0_byteenable;
wire [63:0] m0_readdata;
wire        m0_readdatavalid, m0_waitrequest;

reg         beat1;          // the second beat of the line is next
reg         busy;           // the request is being served

always @(posedge clk) begin
	if (reset) begin
		cpu_ack  <= cpu_req;
		m0_read  <= 1'b0;
		m0_write <= 1'b0;
		beat1    <= 1'b0;
		busy     <= 1'b0;
	end
	else begin
		if ((m0_read || m0_write) && !m0_waitrequest) begin
			m0_read  <= 1'b0;
			m0_write <= 1'b0;
			if (m0_write) begin
				cpu_ack <= cpu_req;
				busy    <= 1'b0;
			end
		end
		if (m0_readdatavalid) begin
			if (!beat1) begin
				cpu_rdata[127:64] <= {rev32(m0_readdata[31:0]), rev32(m0_readdata[63:32])};
				beat1 <= 1'b1;
			end
			else begin
				cpu_rdata[63:0] <= {rev32(m0_readdata[31:0]), rev32(m0_readdata[63:32])};
				beat1   <= 1'b0;
				cpu_ack <= cpu_req;
				busy    <= 1'b0;
			end
		end
		if (cpu_req != cpu_ack && !busy) begin
			busy <= 1'b1;
			if (cpu_we) begin
				m0_address    <= {3'b001, cpu_addr[28:3]};
				m0_burstcount <= 8'd1;
				m0_writedata  <= {rev32(cpu_wdata), rev32(cpu_wdata)};
				m0_byteenable <= cpu_addr[2] ? {cpu_be[0], cpu_be[1], cpu_be[2], cpu_be[3], 4'b0000}
				                             : {4'b0000, cpu_be[0], cpu_be[1], cpu_be[2], cpu_be[3]};
				m0_write      <= 1'b1;
			end
			else begin
				m0_address    <= {3'b001, cpu_addr[28:4], 1'b0};
				m0_burstcount <= 8'd2;
				m0_read       <= 1'b1;
			end
		end
	end
end

wire [28:0] hs_address;
wire  [7:0] hs_burstcount;
wire        hs_read, hs_write, hs_waitrequest;
wire [63:0] hs_writedata;
wire  [7:0] hs_byteenable;

a2065_ddram_arbiter arb
(
	.clk             (clk),
	.rst             (reset),

	.m0_address      (m0_address),
	.m0_burstcount   (m0_burstcount),
	.m0_read         (m0_read),
	.m0_readdata     (m0_readdata),
	.m0_readdatavalid(m0_readdatavalid),
	.m0_writedata    (m0_writedata),
	.m0_byteenable   (m0_byteenable),
	.m0_write        (m0_write),
	.m0_waitrequest  (m0_waitrequest),

	.m1_address      (mem2_address),
	.m1_burstcount   (mem2_burstcount),
	.m1_read         (mem2_read),
	.m1_readdata     (mem2_readdata),
	.m1_readdatavalid(mem2_readdatavalid),
	.m1_writedata    (mem2_writedata),
	.m1_byteenable   (mem2_byteenable),
	.m1_write        (mem2_write),
	.m1_waitrequest  (mem2_waitrequest),

	.s_address       (hs_address),
	.s_burstcount    (hs_burstcount),
	.s_read          (hs_read),
	.s_readdata      (DDRAM_DOUT),
	.s_readdatavalid (DDRAM_DOUT_READY),
	.s_writedata     (hs_writedata),
	.s_byteenable    (hs_byteenable),
	.s_write         (hs_write),
	.s_waitrequest   (hs_waitrequest)
);

// a register stage in front of the HPS bridge (Minimig's ddram_hold)
reg        h_v = 0;
reg [28:0] h_address;
reg  [7:0] h_burstcount;
reg        h_read, h_write;
reg [63:0] h_writedata;
reg  [7:0] h_byteenable;

assign hs_waitrequest = h_v;
assign DDRAM_ADDR     = h_v ? h_address    : hs_address;
assign DDRAM_BURSTCNT = h_v ? h_burstcount : hs_burstcount;
assign DDRAM_RD       = h_v ? h_read       : hs_read;
assign DDRAM_DIN      = h_v ? h_writedata  : hs_writedata;
assign DDRAM_BE       = h_v ? h_byteenable : hs_byteenable;
assign DDRAM_WE       = h_v ? h_write      : hs_write;

always @(posedge clk) begin
	if (~h_v) begin
		h_address    <= hs_address;
		h_burstcount <= hs_burstcount;
		h_read       <= hs_read;
		h_writedata  <= hs_writedata;
		h_byteenable <= hs_byteenable;
		h_write      <= hs_write;
	end
	if (reset) h_v <= 0;
	else if (h_v) h_v <= DDRAM_BUSY;
	else h_v <= (hs_read | hs_write) & DDRAM_BUSY;
end

endmodule
