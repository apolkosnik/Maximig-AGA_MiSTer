//============================================================================
//  a4k_sdram: the SDRAM controller
//
//  Minimig's sdram_ctrl (Tobias Gubener, Alexey Melnikov) with its chip
//  port and slot timing unchanged -- one access per 7 MHz cycle, sixteen
//  clk_114 states locked to c_7m, CAS latency 2, bursts of four, the chip
//  bus first -- and its CPU side replaced for the A4000's motherboard:
//
//  * chip port: chip RAM for Alice's DMA and the CPU's chip-bus cycles,
//    and the HPS's writes of the ROM (the sram bridge's bank mapping),
//    exactly as Minimig drives it (chip48 for the AGA 64-bit fetch,
//    chip32/chipWR2/chipRD2 for the 32-bit CPU cycle).
//  * CPU port (a4k_lbus, toggle handshake): the Kickstart ROM and Ramsey's
//    motherboard RAM.  A read returns the quad word at cpu_addr[24:3] (one
//    burst of four words); a write stores the long word at cpu_addr[24:2]
//    with its byte enables (two column writes in one slot, as chip32 does).
//    It takes the slots the chip bus leaves free -- the real board's fast
//    RAM is a separate DRAM array, and the chip bus never waits for it.
//
//  Words are big-endian: the word at the even byte address holds the byte
//  at that address in D15-D8, the quad word's first word is in [63:48].
//============================================================================

module a4k_sdram
(
	// system
	input             sysclk,
	input             c_7m,
	input             reset_n,
	// sdram
	output reg [12:0] sd_addr,
	output reg  [1:0] sd_ba,
	output            sd_cs,
	output reg        sd_we,
	output reg        sd_ras,
	output reg        sd_cas,
	output reg  [1:0] sd_dqm,
	inout  reg [15:0] sd_data,
	output reg        sd_clk,
	output            sd_cke,
	// chip
	input      [24:1] chipAddr,
	input             chipL,
	input             chipU,
	input             chipRW,
	input             chipDMA,
	input      [15:0] chipWR,
	output reg [15:0] chipRD,
	output     [47:0] chip48,
	input             chip32,
	input      [15:0] chipWR2,
	output reg [15:0] chipRD2,
	// cpu (toggle handshake)
	input             cpu_req,
	output reg        cpu_ack,
	input      [24:2] cpu_addr,
	input             cpu_we,
	input       [3:0] cpu_be,
	input      [31:0] cpu_wdata,
	output reg [63:0] cpu_rdata
);

assign sd_cs = 0;
assign sd_cke = 1;

localparam [1:0] IDLE = 2'd0, CHIP = 2'd1, CPU_RD = 2'd2, CPU_WR = 2'd3;

////////////////////////////////////////
// reset
////////////////////////////////////////

reg reset;
always @(posedge sysclk) begin
	reg [7:0] reset_cnt;

	if(!reset_n) begin
		reset_cnt     <= 0;
		reset         <= 0;
	end else begin
		if(reset_cnt == 170) begin
			if(sdram_state == 15) reset <= 1;
		end
		else begin
			reset_cnt <= reset_cnt + 8'd1;
		end
	end
end

//// chip line read ////
reg [15:0] chip48_1, chip48_2, chip48_3;

always @ (posedge sysclk) begin
	reg [15:0] sdata_chip;

	sdata_chip <= sdata_reg;
	if(slot_type == CHIP) begin
		case(sdram_state)
			 9: chipRD   <= sdata_chip;
			11: begin
					chip48_1 <= sdata_chip;
					if(a_rd2) chipRD2 <= sdata_chip;
				end
			13: chip48_2 <= sdata_chip;
			15: chip48_3 <= sdata_chip;
		endcase
	end
end

assign chip48 = {chip48_1, chip48_2, chip48_3};

////////////////////////////////////////
// SDRAM control
////////////////////////////////////////

//// init counter ////
reg [3:0] initstate;
reg       init_done;
always @ (posedge sysclk) begin
	if(!reset) begin
		initstate <= 0;
		init_done <= 0;
	end else begin
		if (sdram_state == 15) begin
			if(~&initstate) initstate <= initstate + 1'd1;
			else init_done <= 1;
		end
	end
end

//// sdram state ////
reg [3:0] sdram_state;
always @ (posedge sysclk) begin
	reg old_7m;

	sdram_state <= sdram_state + 1'd1;

	old_7m <= c_7m;
	if(~old_7m & c_7m) sdram_state <= 0;
end

//// sdram control ////

reg  [1:0] slot_type = IDLE;
reg [15:0] sdata_reg;
reg        a_wr2 = 0;
reg        a_rd2 = 0;
reg [15:0] datawr2;
reg  [1:0] dqm2;

always @ (posedge sysclk) begin
	reg        cas_sd_cas;
	reg        cas_sd_we;
	reg  [1:0] cas_dqm;
	reg [15:0] datawr;
	reg  [9:0] casaddr;
	reg  [3:0] rcnt;

	sd_clk <= sdram_state[0];

	if(~sdram_state[0]) begin
		sd_ras                <= 1;
		sd_cas                <= 1;
		sd_we                 <= 1;
		sd_data               <= 16'hZZZZ;
	end

	if(sdram_state[0]) sdata_reg <= sd_data;

	if(!init_done) begin
		slot_type             <= IDLE;
		casaddr               <= 0;
		rcnt                  <= 0;
		a_wr2                 <= 0;
		a_rd2                 <= 0;
		sd_dqm                <= 3;
		sd_ba                 <= 0;
		cpu_ack               <= cpu_req;
		if(sdram_state == 0) begin
			case(initstate)
				4 : begin // PRECHARGE
					sd_addr[10]  <= 1; // all banks
					sd_ras       <= 0;
					sd_cas       <= 1;
					sd_we        <= 0;
				end
				8,10 : begin // AUTOREFRESH
					sd_ras       <= 0;
					sd_cas       <= 0;
					sd_we        <= 1;
				end
				13 : begin // LOAD MODE REGISTER
					sd_ras       <= 0;
					sd_cas       <= 0;
					sd_we        <= 0;
					sd_addr      <= 13'b0001000100010; // CL=2, BURST=4, single writes
				end
			endcase
		end
	end else begin

		case(sdram_state)

			// RAS
			0 : begin
				cas_sd_cas      <= 1;
				cas_sd_we       <= 1;
				cas_dqm         <= 0;
				sd_dqm          <= 3;
				slot_type       <= IDLE;
				a_wr2           <= 0;
				a_rd2           <= 0;

				if(~&rcnt) rcnt <= rcnt + 1'd1;

				// the chip bus first (Alice's DMA, the CPU's chip cycles, the HPS)
				if(~chipDMA | ~chipRW) begin
					slot_type    <= CHIP;
					{sd_ba,sd_addr,casaddr[8:0]} <= chipAddr;
					sd_ras       <= 0;
					cas_dqm      <= {chipU,chipL};
					cas_sd_cas   <= 0;
					cas_sd_we    <= chipRW;
					datawr       <= chipWR;
					a_wr2        <= chip32 & !chipRW;
					a_rd2        <= chip32 &  chipRW;
					datawr2      <= chipWR2;
					dqm2         <= 2'b00;
				end
				// the motherboard: ROM and Ramsey's RAM
				else if(cpu_req != cpu_ack) begin
					slot_type    <= cpu_we ? CPU_WR : CPU_RD;
					{sd_ba,sd_addr,casaddr[8:0]} <= {cpu_addr[24:3], cpu_we ? cpu_addr[2] : 1'b0, 1'b0};
					sd_ras       <= 0;
					cas_sd_cas   <= 0;
					cas_sd_we    <= !cpu_we;
					cas_dqm      <= ~cpu_be[3:2];
					datawr       <= cpu_wdata[31:16];
					a_wr2        <= cpu_we;
					datawr2      <= cpu_wdata[15:0];
					dqm2         <= ~cpu_be[1:0];
				end
				else if(&rcnt) begin
					// REFRESH
					sd_ras       <= 0;
					sd_cas       <= 0;
					rcnt         <= 0;
				end
			end

			// CAS
			2 : begin
				sd_addr         <= {~a_wr2, casaddr}; // AUTO PRECHARGE
				sd_cas          <= cas_sd_cas;
				sd_dqm          <= 0;
				if(!cas_sd_we) begin
					sd_data      <= datawr;
					sd_addr[12:11]<= cas_dqm;
					sd_dqm       <= cas_dqm;
					sd_we        <= 0;
				end
			end

			4 : if(a_wr2) begin
				// the second word of a long write, with auto precharge
				sd_addr         <= {2'b00, 1'b1, casaddr[9:1], 1'b1};
				sd_addr[12:11]  <= dqm2;
				sd_dqm          <= dqm2;
				sd_data         <= datawr2;
				sd_cas          <= 0;
				sd_we           <= 0;
			end

			6 : if(slot_type == CPU_WR) cpu_ack <= cpu_req;

			15: if(slot_type == CPU_RD) cpu_ack <= cpu_req;
		endcase

		// the CPU's quad word: sdata_reg holds the word sampled at the end of
		// states 7, 9, 11, 13 during the state after (the chip side's
		// sdata_chip stage is the same delay)
		if(slot_type == CPU_RD) begin
			case(sdram_state)
				 8: cpu_rdata[63:48] <= sdata_reg;
				10: cpu_rdata[47:32] <= sdata_reg;
				12: cpu_rdata[31:16] <= sdata_reg;
				14: cpu_rdata[15:0]  <= sdata_reg;
			endcase
		end
	end
end

endmodule
