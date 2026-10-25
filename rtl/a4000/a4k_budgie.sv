//============================================================================
//  a4k_budgie: the motherboard's slow side (28 MHz)
//
//  Serves the local bus's beats (a4k_lbus) for everything that sits on the
//  16-bit buses of the A4000 board:
//
//  * chip RAM, the custom registers and the CIAs, through Alice's CPU port:
//    Minimig's 68000-style bridge (minimig_m68k_bridge), whose 7 MHz bus
//    cycles, DMA slots and E-clock synchronised CIA cycles are those of the
//    chip bus.  A long word to chip RAM is one 32-bit cycle (the AGA CPU
//    path, cpu_long); every other long word is two 16-bit cycles, high word
//    first, as the 68030-style motherboard bus sizes a 16-bit port.  A
//    chip-bus access can also wait CHIP_SYNC colour clocks after the chip
//    bus has terminated it (Budgie's resynchronisation to the CPU bus); it
//    is 0: the bridge and the card's own cost already give the A3640's
//    measured chip line fill (tb/system/timing_check.py), so Fast timing
//    changes nothing on the chip bus.
//  * the RP5C01 (a4k_rtc): 4-bit registers on the odd byte of $DC0000+4n.
//  * the A4000 IDE (ide.v): the task file at $DD2020+4n, data on D31-D16 of
//    the long word at $DD2020, byte registers on D15-D8 (Linux pata_gayle:
//    base + 2 + 4n); the control block at $DD3020+4n (alternate status /
//    device control at $DD3038); the interrupt status at $DD3020, bit 7 the
//    drive's INTRQ.  PIO cycles take IDE_CYC clocks in A4000 timing.
//  * the Zorro II boards (A2065, Toccata) with Buster's Zorro II cycle,
//    Z2_CYC clocks per 16-bit cycle in A4000 timing.
//
//  Byte lanes: be[3] is the byte at offset 0 (D31-D24).  be[3:2] is the
//  16-bit word at A1 = 0, be[1:0] the word at A1 = 1.
//============================================================================

module a4k_budgie
#(
	parameter int CHIP_SYNC = 0,    // colour clocks of resynchronisation after a chip-bus access
	parameter int IDE_CYC   = 17,   // ~600 ns: PIO mode 0 cycle
	parameter int Z2_CYC    = 16,   // ~560 ns: four 7 MHz clocks
	parameter int RTC_CYC   = 8     // ~280 ns
)
(
	input             clk,          // clk_sys, 28 MHz
	input             reset,
	input             fast,         // no added wait states
	input             clk7_en,      // 7 MHz (amiga_clk)
	input             cck,          // colour clock (amiga_clk)

	// beats from a4k_lbus (toggle handshake, fields stable while pending)
	input             sb_req,
	output reg        sb_ack,
	input       [2:0] sb_tgt,
	input      [23:2] sb_addr,
	input             sb_we,
	input       [3:0] sb_be,
	input      [31:0] sb_wdata,
	output reg [31:0] sb_rdata,

	// Alice's CPU port (minimig_m68k_bridge, in a4k_chipset)
	output reg [23:1] cpu_addr,
	output reg [15:0] cpu_dout,     // write data, the high word of a long
	output reg [15:0] cpu_dout2,    // the low word of a long write
	output reg        cpu_as_n,
	output reg        cpu_uds_n,
	output reg        cpu_lds_n,
	output reg        cpu_rw,
	output reg        cpu_long,
	input             cpu_dtack_n,
	input      [15:0] cpu_din,      // read data, the high word of a long
	input      [15:0] cpu_din2,     // the low word of a long read
	input             chip32_en,    // 32-bit chip RAM cycles available

	// RP5C01
	output reg        rtc_cs,
	output reg        rtc_we,
	output reg  [3:0] rtc_reg,
	output reg  [3:0] rtc_wdata,
	input       [3:0] rtc_rdata,

	// IDE (ide.v io port)
	output reg  [3:0] ide_addr,
	output reg        ide_rd,
	output reg        ide_wr,
	output reg [15:0] ide_wdata,
	input      [15:0] ide_rdata,
	input             ide_nodata,   // fast-read data not there yet
	input             ide_irq,
	input             ide_reset,     // the IDE's reset (RST): clears the latched interrupt status
	input       [1:0] ide_present,  // drives fitted (ide.v drive_en)

	// Zorro II boards: 68000-style A2065, strobed Toccata
	output reg [23:1] z2_addr,
	output reg [15:0] z2_dout,
	output reg        z2_rw,
	output reg        z2_as_n,
	output reg        z2_uds_n,
	output reg        z2_lds_n,
	output reg        a2065_sel,
	input      [15:0] a2065_din,
	input             a2065_nrdy,
	output reg        tocc_sel,
	output reg        tocc_rd,
	output reg        tocc_hwr,
	output reg        tocc_lwr,
	input      [15:0] tocc_din
);

localparam [2:0] SB_CHIP = 3'd0, SB_CREG = 3'd1, SB_CIA = 3'd2, SB_RTC = 3'd3,
                 SB_IDE = 3'd4, SB_A2065 = 3'd5, SB_TOCC = 3'd6;

localparam [3:0] S_IDLE = 4'd0, S_CYC = 4'd1, S_CHIP = 4'd2, S_CHIPEND = 4'd3, S_SYNC = 4'd4,
                 S_RTC = 4'd5, S_IDE = 4'd6, S_IDE2 = 4'd7, S_Z2 = 4'd8, S_Z2END = 4'd9, S_NEXT = 4'd10;

reg  [3:0] st;
reg        hi;          // the cycle in progress is the word at A1 = 0
reg        both;        // the beat needs both words
reg  [5:0] cnt;
reg  [1:0] sync;
reg        e7_seen;     // a 7 MHz edge since AS was negated
reg        as_idle;     // the bridge has latched AS negated, DTACK has followed
reg        dtack_seen;  // the bridge has answered the cycle
reg  [1:0] e7_cnt;      // 7 MHz edges since
reg        ide_cap;     // the strobe has been seen by ide.v
reg        ide_cap_done;
reg        cck_d;
wire       cck_rise = cck & ~cck_d;
reg        irq_seen;

// the word of this cycle: its strobes and write data
wire [1:0] wbe = hi ? sb_be[3:2] : sb_be[1:0];
wire [15:0] wdat = hi ? sb_wdata[31:16] : sb_wdata[15:0];

task automatic put_word(input [15:0] d);
	if (hi) sb_rdata[31:16] <= d;
	else    sb_rdata[15:0]  <= d;
endtask

// IDE register of the beat: {CS1, A4:A2}; $DD3020 (CS1, register 0) is the
// interrupt status
wire [3:0] ide_reg  = {sb_addr[12], sb_addr[4:2]};
wire       ide_istat = sb_addr[12] && sb_addr[4:2] == 3'd0;

always @(posedge clk) begin
	cck_d <= cck;
	if (reset) begin
		st        <= S_IDLE;
		sb_ack    <= sb_req;
		cpu_as_n  <= 1'b1;
		cpu_uds_n <= 1'b1;
		cpu_lds_n <= 1'b1;
		cpu_rw    <= 1'b1;
		cpu_long  <= 1'b0;
		dtack_seen <= 1'b0;
		as_idle   <= 1'b1;
		e7_seen   <= 1'b1;
		rtc_cs    <= 1'b0;
		rtc_we    <= 1'b0;
		ide_rd    <= 1'b0;
		ide_wr    <= 1'b0;
		z2_as_n   <= 1'b1;
		z2_uds_n  <= 1'b1;
		z2_lds_n  <= 1'b1;
		a2065_sel <= 1'b0;
		tocc_sel  <= 1'b0;
		tocc_rd   <= 1'b0;
		tocc_hwr  <= 1'b0;
		tocc_lwr  <= 1'b0;
		irq_seen  <= 1'b0;
	end
	else begin
		ide_rd <= 1'b0;
		ide_wr <= 1'b0;

		case (st)
			S_IDLE: if (sb_req != sb_ack) begin
				sb_rdata <= 32'hFFFFFFFF;
				both     <= |sb_be[3:2] && |sb_be[1:0];
				hi       <= |sb_be[3:2];
				st       <= S_CYC;
			end

			S_CYC: begin
				// one bus cycle of the beat (the word at A1 = hi ? 0 : 1)
				case (sb_tgt)
					SB_CHIP, SB_CREG, SB_CIA: if (as_idle) begin
						cpu_addr  <= {sb_addr[23:2], ~hi};
						cpu_rw    <= !sb_we;
						cpu_dout  <= wdat;
						cpu_dout2 <= sb_wdata[15:0];
						// a long word to chip RAM: one 32-bit cycle
						if (sb_tgt == SB_CHIP && sb_be == 4'b1111 && chip32_en) begin
							cpu_long  <= 1'b1;
							cpu_uds_n <= 1'b0;
							cpu_lds_n <= 1'b0;
							both      <= 1'b0;
						end
						else begin
							cpu_long  <= 1'b0;
							cpu_uds_n <= !wbe[1];
							cpu_lds_n <= !wbe[0];
						end
						cpu_as_n <= 1'b0;
						st       <= S_CHIP;
					end
					SB_RTC: begin
						// the clock answers on the odd byte, D3-D0
						rtc_cs    <= 1'b1;
						rtc_we    <= sb_we && wbe[0];
						rtc_reg   <= sb_addr[5:2];
						rtc_wdata <= wdat[3:0];
						cnt       <= fast ? 6'd2 : 6'(RTC_CYC);
						st        <= S_RTC;
					end
					SB_IDE: begin
						if (ide_istat) begin
							put_word({irq_seen | ide_irq, 7'h00, 8'h00});
							cnt <= fast ? 6'd1 : 6'(IDE_CYC);
							st  <= S_IDE2;
						end
						else if (ide_present == 2'b00) begin
							// no drive: DD7 is pulled down (ATA), so the status reads
							// $7F (not busy) and everything else floats high, as
							// WinUAE's gayle_read2 answers
							put_word((ide_reg == 4'd7 || ide_reg == 4'd14) ? 16'h7F7F : 16'hFFFF);
							cnt <= fast ? 6'd1 : 6'(IDE_CYC);
							st  <= S_IDE2;
						end
						else if (!sb_we && ide_reg == 4'd0 && ide_nodata) begin
							// the HPS has not delivered the data yet
						end
						else begin
							ide_addr  <= ide_reg;
							ide_rd    <= !sb_we;
							ide_wr    <= sb_we;
							// the data register is 16 bits, little-endian on ide.v's
							// side (as Minimig's Gayle); byte registers on D15-D8
							ide_wdata <= (ide_reg == 4'd0) ? {wdat[7:0], wdat[15:8]} : {8'h00, wdat[15:8]};
							ide_cap   <= 1'b0;
							ide_cap_done <= 1'b0;
							cnt       <= fast ? 6'd2 : 6'(IDE_CYC);
							st        <= S_IDE;
						end
					end
					default: begin
						// a Zorro II board
						z2_addr   <= {sb_addr[23:2], ~hi};
						z2_rw     <= !sb_we;
						z2_dout   <= wdat;
						z2_as_n   <= 1'b0;
						z2_uds_n  <= !wbe[1];
						z2_lds_n  <= !wbe[0];
						a2065_sel <= (sb_tgt == SB_A2065);
						tocc_sel  <= (sb_tgt == SB_TOCC);
						tocc_rd   <= (sb_tgt == SB_TOCC) && !sb_we;
						tocc_hwr  <= (sb_tgt == SB_TOCC) && sb_we && wbe[1];
						tocc_lwr  <= (sb_tgt == SB_TOCC) && sb_we && wbe[0];
						cnt       <= fast ? 6'd4 : 6'(Z2_CYC);
						st        <= S_Z2;
					end
				endcase
			end

			S_CHIP: begin
				// minimig_m68k_bridge answers DTACK first and then runs the
				// access: its strobes are on in the colour-clock-low 7 MHz
				// cycle after it has latched DTACK (enable = ~l_as & ~l_dtack
				// & ~cck), and the read data is latched in it.  So AS stays
				// asserted over the next two 7 MHz edges -- the start and the
				// end of that cycle -- and goes in the colour-clock-high cycle
				// after it, before a second enable cycle could begin.
				if (!cpu_dtack_n && !dtack_seen) begin
					dtack_seen <= 1'b1;
					e7_cnt     <= 2'd0;
				end
				if (dtack_seen && clk7_en) e7_cnt <= e7_cnt + 1'd1;
				if (dtack_seen && e7_cnt == 2'd2) begin
					if (cpu_long) sb_rdata <= {cpu_din, cpu_din2};
					else          put_word(cpu_din);
					cpu_as_n   <= 1'b1;
					cpu_uds_n  <= 1'b1;
					cpu_lds_n  <= 1'b1;
					dtack_seen <= 1'b0;
					e7_seen    <= 1'b0;
					st         <= S_CHIPEND;
				end
			end

			S_CHIPEND: begin
				// the data is in: the beat goes on at once; the next chip-bus
				// cycle waits for the bridge to have latched AS negated
				// (as_idle) and DTACK to have followed it
				cpu_long <= 1'b0;
				sync     <= fast ? 2'd0 : 2'(CHIP_SYNC);
				st       <= (CHIP_SYNC == 0 || fast) ? S_NEXT : S_SYNC;
			end

			S_SYNC: begin
				if (sync == 2'd0) st <= S_NEXT;
				else if (cck_rise) sync <= sync - 1'd1;
			end

			S_RTC: begin
				rtc_we <= 1'b0;
				if (cnt <= 6'd1) begin
					put_word({4'h0, rtc_rdata, 4'h0, rtc_rdata});
					rtc_cs <= 1'b0;
					st     <= S_NEXT;
				end
				else cnt <= cnt - 1'd1;
			end

			S_IDE: begin
				// ide.v registers its read data at the strobe: it is there the
				// clock after that
				ide_cap <= 1'b1;
				if (ide_cap) ide_cap_done <= 1'b1;
				if (ide_cap && !ide_cap_done) begin
					if (!sb_we) put_word((ide_reg == 4'd0) ? {ide_rdata[7:0], ide_rdata[15:8]} : {ide_rdata[7:0], ide_rdata[7:0]});
				end
				if (cnt <= 6'd1) st <= S_NEXT;
				else cnt <= cnt - 1'd1;
			end

			S_IDE2: begin
				// reading the interrupt status drops the latched request
				irq_seen <= 1'b0;
				if (cnt <= 6'd1) st <= S_NEXT;
				else cnt <= cnt - 1'd1;
			end

			S_Z2: begin
				if (cnt > 6'd1) cnt <= cnt - 1'd1;
				else if (!(a2065_sel && a2065_nrdy)) begin
					put_word(a2065_sel ? a2065_din : tocc_din);
					z2_as_n   <= 1'b1;
					z2_uds_n  <= 1'b1;
					z2_lds_n  <= 1'b1;
					tocc_rd   <= 1'b0;
					tocc_hwr  <= 1'b0;
					tocc_lwr  <= 1'b0;
					st        <= S_Z2END;
				end
			end

			S_Z2END: begin
				a2065_sel <= 1'b0;
				tocc_sel  <= 1'b0;
				st        <= S_NEXT;
			end

			S_NEXT: begin
				if (both && hi) begin
					hi <= 1'b0;
					st <= S_CYC;
				end
				else begin
					sb_ack <= sb_req;
					st     <= S_IDLE;
				end
			end

			default: st <= S_IDLE;
		endcase

		// INTRQ is held for the interrupt status register until it is read,
		// or the IDE is reset with the machine (RST: a warm reset, RESET)
		if (ide_reset) irq_seen <= 1'b0;
		else if (ide_irq) irq_seen <= 1'b1;

		// the bridge latches AS at 7 MHz edges: once AS has been negated over
		// one, and DTACK has followed, the next cycle may start
		if (!cpu_as_n) begin
			as_idle <= 1'b0;
			e7_seen <= 1'b0;
		end
		else begin
			if (clk7_en) e7_seen <= 1'b1;
			if (e7_seen && cpu_dtack_n) as_idle <= 1'b1;
		end
	end
end

endmodule
