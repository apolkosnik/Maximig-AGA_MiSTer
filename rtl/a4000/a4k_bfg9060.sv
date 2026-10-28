//============================================================================
//  a4k_bfg9060: the BFG9060 card with a 68040
//
//  Matthias Heinrichs' BFG9060 (gitlab.com/MHeinrichs/a4000-tk), its 68040
//  firmware (control.vhd, ramcon.vhd, mcp.vhd with FOR_68060 = 0), in place
//  of the A3640.  The 68040's only bus slave, synchronous to its bus as
//  a4k_a3640 is (state changes at the base cycles that end on a CPU clock
//  edge, ce): what is registered at such an edge, the core samples at the
//  next.  A TS the core drives after edge k is seen here at k+1; a TA
//  registered at k+1 is sampled by the core at k+2.
//
//  * The card's 128 MB of SDRAM at $08000000-$0FFFFFFF (A31-A27 = 00001;
//    Kickstart sizes it as CPU-slot RAM, no AUTOCONFIG).  ramcon runs the
//    SDRAM at twice the bus clock; counted in bus clocks from TS, a read's
//    first TA is sampled at k+3 and a burst's later ones one bus clock
//    apart (3-1-1-1), a write's first at k+2 and then 1-1-1.  A refresh
//    every 6.4 us (160 motherboard clocks) takes 3 bus clocks.  The memory
//    is DDR3 behind a4k_lbus (lb_local): a read waits for its line, the
//    burst's later long words come from it; writes are posted, four deep,
//    and drained before the next local bus beat.  The burst write's data:
//    the core drives the next long word after it has sampled a TA, so it is
//    taken a clock after that beat's TA.
//  * Everything else is a 68030-style motherboard cycle per long word, as
//    on the A3640 (a4k_lbus's region times, the card's PRE/POST clocks):
//    TBI is asserted with the first TA of a line (control.vhd: "burst only
//    local ram"), so the core fetches the rest as long words.
//  * TCI (ramcon's CACHE_INHIBIT, control.vhd's TCI40): data is
//    cache-inhibited except in the card's RAM, $01000000-$07FFFFFF,
//    $10000000-$7FFFFFFF and $00F00000-$00FFFFFF; instruction fetches are
//    never inhibited.  So chip RAM's data is not cached, Zorro III space is.
//  * The flash at $F00000-$F7FFFF (512 KB, 8-bit port): the boot code
//    (bfg9060_rom.svh), read-only.  Each byte is one 68030 cycle on the
//    card's CPLD: DSACK0 two motherboard clocks after AS, four clocks a
//    byte (mcp.vhd's ROM decode, control.vhd's dynamic bus sizing).  The
//    cycle is driven onto the motherboard as well; a write goes to the
//    local bus (posted) so what watches it there sees it.
//  * The firmware ID: a read of $FF040008 returns $BF690601 (bus_sizing.vhd,
//    "the magic firmware code"); $FF040000-$FF0400FF is answered 32 bits
//    wide by the card (the rest of it reads all ones).
//  * Interrupt acknowledge: TA with AVEC a bus clock after TS (control.vhd's
//    INT_CYCLE; Gary autovectors every interrupt), no motherboard cycle.
//============================================================================

module a4k_bfg9060
(
	input             clk,
	input             ce,
	input             reset,

	// the 68040's bus, as the core drives it
	input      [31:0] a,
	input             ts_n,
	input             rw_n,
	input       [1:0] siz,
	input       [1:0] tt,
	input       [2:0] tm,
	input      [31:0] d_cpu,

	// to the core
	output reg [31:0] d_mem,
	output reg        ta_n,
	output reg        tea_n,
	output reg        tci_n,
	output reg        tbi_n,
	output reg        avec_n,
	output reg        iack7_t = 1'b0, // toggles at each level-7 interrupt acknowledge

	// the motherboard cycle's synchronisation cost per beat, in CPU clocks
	input       [2:0] pre,
	input       [2:0] post,

	// the motherboard's local bus (a4k_lbus); lb_local: the card's RAM
	output reg        lb_req,
	input             lb_ack,
	output reg [31:2] lb_addr,
	output reg  [3:0] lb_be,
	output reg        lb_we,
	output reg [31:0] lb_wdata,
	output reg        lb_line,
	output reg  [1:0] lb_beat,
	output reg  [1:0] lb_tt,
	output reg  [2:0] lb_tm,
	output reg        lb_local,
	input      [31:0] lb_rdata,
	input             lb_berr,
	input     [127:0] lb_rline,    // the 16-byte line of the last local read

	output      [3:0] dbg_state
);

`include "bfg9060_rom.svh"

// motherboard clocks (25 MHz) in base clocks (56.75 MHz), rounded up
localparam int MB_SYNC  = 3;    // AS on the card's CPLD after TS: up to a clock
localparam int MB_FLASH = 10;   // a flash byte: four clocks
localparam int MB_FWID  = 7;    // the firmware ID: one 68030 cycle, three clocks
localparam int RF_IVAL  = 363;  // a refresh every 160 clocks (6.4 us)

// byte lanes of a byte, word or long transfer (MC68040UM table 7-1); [3] is
// the byte at offset 0 mod 4, D31-D24
function automatic [3:0] lanes(input [1:0] s, input [1:0] a10);
	case (s)
		2'b01:   lanes = 4'b1000 >> a10;
		2'b10:   lanes = a10[1] ? 4'b0011 : 4'b1100;
		default: lanes = 4'b1111;
	endcase
endfunction

function automatic [31:0] l_long(input [127:0] l, input [1:0] a32);
	case (a32)
		2'd0:    l_long = l[127:96];
		2'd1:    l_long = l[95:64];
		2'd2:    l_long = l[63:32];
		default: l_long = l[31:0];
	endcase
endfunction

// the CACHE_INHIBIT decode (ramcon.vhd): the card's RAM, the motherboard's
// fast RAM space, Zorro III space and $00Fxxxxx are cacheable
function automatic cacheable(input [31:0] x);
	cacheable = (x[31:27] == 5'b00001) ||
	            (x[31:27] == 5'b00000 && x[26:24] != 3'd0) ||
	            (!x[31] && x[30:28] != 3'd0) ||
	            (x[31:20] == 12'h00F);
endfunction

localparam [3:0] X_IDLE = 4'd0, X_PRE = 4'd1, X_BUS = 4'd2, X_POST = 4'd3, X_TA = 4'd4,
                 L_RD = 4'd5, L_RDB = 4'd6, L_WR = 4'd7, X_LOC = 4'd8, X_FLASH = 4'd9,
                 X_FWID = 4'd10, X_ISSUE = 4'd11, L_WQ = 4'd12, X_FLASHW = 4'd13;
reg  [3:0] xst;
reg  [2:0] cnt;
reg [31:0] xa, xwd;
reg  [3:0] xbe;
reg  [1:0] xtt;
reg  [2:0] xtm;
reg        xline, xrd;
reg  [1:0] beat;
reg [31:0] rdat;
reg        rerr;
reg  [3:0] lcnt;            // bus clocks to the local access's first TA
reg[127:0] rline;
reg  [7:0] mcnt;            // base clocks of a cycle answered on the card
reg        wtake;           // a burst write: take the data of the beat acknowledged before

assign dbg_state = xst;

// an instruction fetch (TT normal or MOVE16, TM user or supervisor code)
function automatic tt_code(input [1:0] t, input [2:0] m);
	tt_code = !t[1] && (m == 3'b010 || m == 3'b110);
endfunction

// the posted local writes: four deep, drained into the local bus in order
reg [31:2] wq_a [0:3];
reg [31:0] wq_d [0:3];
reg  [3:0] wq_be[0:3];
reg  [2:0] wq_n;
reg  [1:0] wq_rd, wq_wr;
wire       lb_idle  = (lb_req == lb_ack);
wire       wq_empty = (wq_n == 3'd0);
wire       drain    = !wq_empty && lb_idle;    // a queued write goes to the local bus now

// the refresh: due every RF_IVAL base clocks, 3 bus clocks long
reg  [8:0] rf_cnt = 9'd0;
reg  [1:0] rf_left = 2'd0;

wire [1:0] a32 = xa[3:2] + beat;

wire [18:0] fl_off  = {xa[18:2], 2'b00};
wire [31:0] fl_long = {bfg_rom(fl_off), bfg_rom(fl_off + 19'd1), bfg_rom(fl_off + 19'd2), bfg_rom(fl_off + 19'd3)};

// a beat from the card's state machine (fields captured at TS)
task automatic issue(input loc, input [31:2] ad);
	lb_local <= loc;
	lb_addr  <= ad;
	lb_we    <= !xrd;
	lb_be    <= xbe;
	lb_wdata <= xwd;
	lb_line  <= loc && xline;
	lb_beat  <= 2'd0;
	lb_tt    <= xtt;
	lb_tm    <= xtm;
	lb_req   <= ~lb_req;
endtask

// a local write into the queue, its first TA now (or after a refresh)
task automatic local_write();
	wq_a[wq_wr]  <= xa[31:2];
	wq_d[wq_wr]  <= xwd;
	wq_be[wq_wr] <= xbe;
	wq_wr        <= wq_wr + 1'd1;
	if (lcnt == 4'd0) begin
		ta_n <= 1'b0;
		if (xline) begin beat <= 2'd1; xst <= L_WR; end
		else xst <= X_TA;
	end
	else xst <= L_WR;
endtask

always @(posedge clk) begin : seq
	logic push;
	push = 1'b0;
	if (reset) begin
		xst      <= X_IDLE;
		lb_req   <= lb_ack;
		lb_local <= 1'b0;
		ta_n     <= 1'b1;
		tea_n    <= 1'b1;
		tci_n    <= 1'b1;
		tbi_n    <= 1'b1;
		avec_n   <= 1'b1;
		beat     <= 2'd0;
		xline    <= 1'b0;
		wq_n     <= 3'd0;
		wq_rd    <= 2'd0;
		wq_wr    <= 2'd0;
		rf_cnt   <= 9'd0;
		rf_left  <= 2'd0;
		wtake    <= 1'b0;
		mcnt     <= 8'd0;
	end
	else begin
		// the refresh timer runs on the motherboard's clock
		if (rf_cnt == 9'(RF_IVAL - 1)) rf_cnt <= 9'd0;
		else rf_cnt <= rf_cnt + 1'd1;
		if (mcnt != 8'd0) mcnt <= mcnt - 1'd1;

		// the oldest posted local write to the local bus (the state machine
		// issues its own beats only with the queue empty)
		if (drain) begin
			lb_addr  <= wq_a[wq_rd];
			lb_wdata <= wq_d[wq_rd];
			lb_be    <= wq_be[wq_rd];
			lb_we    <= 1'b1;
			lb_line  <= 1'b0;
			lb_beat  <= 2'd0;
			lb_tt    <= 2'b00;
			lb_tm    <= 3'd1;
			lb_local <= 1'b1;
			lb_req   <= ~lb_req;
			wq_rd    <= wq_rd + 1'd1;
		end

		if (ce) begin
			// TA/TEA/AVEC/TCI/TBI are one CPU clock long
			ta_n   <= 1'b1;
			tea_n  <= 1'b1;
			avec_n <= 1'b1;
			tci_n  <= 1'b1;
			tbi_n  <= 1'b1;
			if (rf_left != 2'd0) rf_left <= rf_left - 1'd1;
			if (rf_cnt < 9'd3 && rf_left == 2'd0) rf_left <= 2'd3;

			// a burst write: the long word of the beat acknowledged at the edge
			// before (the core drove it after sampling that TA)
			if (wtake) begin
				wq_a[wq_wr]  <= {xa[31:4], a32 - 2'd1};
				wq_d[wq_wr]  <= d_cpu;
				wq_be[wq_wr] <= 4'b1111;
				wq_wr        <= wq_wr + 1'd1;
				push          = 1'b1;
				wtake        <= 1'b0;
			end

			case (xst)
				X_IDLE: if (!ts_n) begin
					xa    <= a;
					xrd   <= rw_n;
					xwd   <= d_cpu;
					xbe   <= lanes(siz, a[1:0]);
					xtt   <= tt;
					xtm   <= tm;
					xline <= (siz == 2'b11);
					beat  <= 2'd0;
					cnt   <= pre;
					if (tt == 2'b11) begin
						// interrupt acknowledge: autovectored at once; a breakpoint: TA
						ta_n   <= 1'b0;
						avec_n <= (tm == 3'd0);
						if (tm == 3'd7) iack7_t <= ~iack7_t;
						xline  <= 1'b0;
						xst    <= X_TA;
					end
					else if (a[31:27] == 5'b00001) begin
						if (!rw_n) begin
							// a write: into the queue at once (a full queue first
							// drains one), its first TA now or after a refresh
							lcnt <= {2'd0, rf_left};
							if (wq_n != 3'd4) begin
								wq_a[wq_wr]  <= a[31:2];
								wq_d[wq_wr]  <= d_cpu;
								wq_be[wq_wr] <= lanes(siz, a[1:0]);
								wq_wr        <= wq_wr + 1'd1;
								push          = 1'b1;
								if (rf_left == 2'd0) begin
									ta_n <= 1'b0;
									if (siz == 2'b11) begin beat <= 2'd1; xst <= L_WR; end
									else xst <= X_TA;
								end
								else xst <= L_WR;
							end
							else xst <= L_WQ;
						end
						else begin
							// a read: its line from the local bus; the first TA at the
							// next edge at the earliest (3 bus clocks after TS)
							lcnt <= 4'd1 + {2'd0, rf_left};
							if (wq_empty && lb_idle) begin
								lb_local <= 1'b1;
								lb_addr  <= a[31:2];
								lb_we    <= 1'b0;
								lb_be    <= 4'b1111;
								lb_line  <= (siz == 2'b11);
								lb_beat  <= 2'd0;
								lb_tt    <= tt;
								lb_tm    <= tm;
								lb_req   <= ~lb_req;
								xst      <= L_RD;
							end
							else xst <= X_LOC;
						end
					end
					else if (a[31:19] == 13'h001E) begin
						// $F00000-$F7FFFF: the flash, an 8-bit port
						mcnt <= 8'(MB_SYNC) + 8'(MB_FLASH) * ((siz == 2'b01) ? 8'd1 : (siz == 2'b10) ? 8'd2 : 8'd4);
						xst  <= rw_n ? X_FLASH : X_FLASHW;
					end
					else if (a[31:8] == 24'hFF0400) begin
						mcnt <= 8'(MB_SYNC + MB_FWID);
						xst  <= X_FWID;
					end
					else xst <= X_ISSUE;
				end

				X_ISSUE: if (wq_empty && lb_idle) begin
					// a motherboard cycle, behind the posted local writes; a line
					// is one long word (TBI with its TA)
					if (pre == 3'd0) begin
						issue(1'b0, xa[31:2]);
						xst <= X_BUS;
					end
					else xst <= X_PRE;
				end

				X_PRE: begin
					if (cnt <= 3'd1) begin
						issue(1'b0, xa[31:2]);
						xst <= X_BUS;
					end
					else cnt <= cnt - 1'd1;
				end

				X_BUS: if (lb_idle) begin
					rdat <= lb_rdata;
					rerr <= lb_berr;
					if (post == 3'd0) begin
						d_mem <= lb_rdata;
						ta_n  <= lb_berr;
						tea_n <= !lb_berr;
						tci_n <= cacheable(xa) || tt_code(xtt, xtm);
						tbi_n <= !xline;
						xst   <= X_TA;
					end
					else begin
						cnt <= post;
						xst <= X_POST;
					end
				end

				X_POST: begin
					if (cnt <= 3'd1) begin
						d_mem <= rdat;
						ta_n  <= rerr;
						tea_n <= !rerr;
						tci_n <= cacheable(xa) || tt_code(xtt, xtm);
						tbi_n <= !xline;
						xst   <= X_TA;
					end
					else cnt <= cnt - 1'd1;
				end

				X_TA: xst <= X_IDLE;   // (the core samples the termination at this edge)

				// the card's RAM: a read waiting for the posted writes
				X_LOC: begin
					if (lcnt != 4'd0) lcnt <= lcnt - 1'd1;
					if (wq_empty && lb_idle) begin
						issue(1'b1, xa[31:2]);
						xst <= L_RD;
					end
				end

				L_RD: begin
					if (lcnt != 4'd0) lcnt <= lcnt - 1'd1;
					if (lcnt <= 4'd1 && lb_idle) begin
						d_mem <= lb_rdata;
						rline <= lb_rline;
						ta_n  <= lb_berr;
						tea_n <= !lb_berr;
						if (xline && !lb_berr) begin
							beat <= 2'd1;
							xst  <= L_RDB;
						end
						else xst <= X_TA;
					end
				end

				L_RDB: begin
					// the burst's later long words, one a bus clock
					d_mem <= l_long(rline, a32);
					ta_n  <= 1'b0;
					beat  <= beat + 1'd1;
					if (beat == 2'd3) xst <= X_TA;
				end

				L_WR: begin
					// a write that waited for a refresh, or a burst's later beats
					// (the queue has room for the beat taken at the next edge)
					if (lcnt != 4'd0) lcnt <= lcnt - 1'd1;
					else if (beat == 2'd0) begin
						ta_n <= 1'b0;
						if (xline) beat <= 2'd1;
						else xst <= X_TA;
					end
					else if (wq_n < 3'd3) begin
						ta_n  <= 1'b0;
						wtake <= 1'b1;
						beat  <= beat + 1'd1;
						if (beat == 2'd3) xst <= X_TA;
					end
				end

				L_WQ: begin
					if (lcnt != 4'd0) lcnt <= lcnt - 1'd1;
					if (wq_n != 3'd4) begin
						push = 1'b1;
						local_write();
					end
				end

				X_FLASHW: if (wq_empty && lb_idle) begin
					// a write: its 68030 cycle is on the motherboard too (nothing
					// there answers $F00000); the card's DSACK ends it
					issue(1'b0, xa[31:2]);
					xst <= X_FLASH;
				end

				X_FLASH: if (mcnt == 8'd0) begin
					// the bytes the bus sizing assembled; writes go nowhere
					d_mem <= fl_long;
					ta_n  <= 1'b0;
					tbi_n <= !xline;
					xst   <= X_TA;
				end

				X_FWID: if (mcnt == 8'd0) begin
					d_mem <= (xrd && xa[7:2] == 6'd2) ? 32'hBF690601 : 32'hFFFFFFFF;
					ta_n  <= 1'b0;
					tci_n <= 1'b0;
					tbi_n <= !xline;
					xst   <= X_TA;
				end

				default: xst <= X_IDLE;
			endcase
		end
		wq_n <= wq_n + (push ? 3'd1 : 3'd0) - (drain ? 3'd1 : 3'd0);
	end
end

endmodule
