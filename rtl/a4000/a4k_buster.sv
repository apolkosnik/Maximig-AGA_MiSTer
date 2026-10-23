//============================================================================
//  a4k_buster: Super Buster's AUTOCONFIG chain
//
//  The boards of the Zorro slots, configured one at a time in chain order:
//
//    0  Zorro III fast RAM, 256 MB   (mfr $139C, product $10, serial 1)
//    1  Zorro III fast RAM, 128 MB   (mfr $139C, product $10, serial 2)
//    2  Zorro III RTG board, 16 MB   (mfr $139C, product $30: the Minimig
//       Z3 graphics card MiSTer.card and ZZMiSTerRTG drive)
//    3  A2065 Ethernet, Zorro II I/O, 64 KB (Commodore $0202, product $70)
//    4  Toccata, Zorro II I/O, 64 KB (MacroSystem $4754, product $0C)
//
//  A board that is not fitted is not in the chain.  The current board's
//  configuration ROM answers in both configuration spaces:
//
//  * $00E80000 (Zorro II layout): register nibble n in bits 7-4 of the byte
//    at offset 2n; odd bytes read 0.  Kickstart 3.1 configures Zorro III
//    boards here too (WinUAE expansion.cpp).
//  * $FF000000 (Zorro III layout): offset X reads the Zorro II byte at
//    (X & $FF) + (X & $100 ? 2 : 0), as WinUAE's expamemz3_bget.
//
//  Writes (byte offsets in the Zorro II layout): $48 sets a Zorro II
//  board's base (A23-A16) and configures it, $4A holds A19-A16 for it; $44
//  (word: A31-A16, or byte: A31-A24 after $48 gave A23-A16) configures a
//  Zorro III board; $4C shuts the board up.  Reads past the last board
//  return zero, which ends Kickstart's chain walk.
//
//  The register nibbles are given as read: er_Type (registers 0-1) plain,
//  everything after it inverted, as the Zorro specification stores them.
//============================================================================

module a4k_buster
(
	input             clk,
	input             reset,           // the chain restarts at every reset

	// fitted boards
	input             z3ram256_fit,
	input             z3ram128_fit,
	input             rtg_fit,
	input             a2065_fit,
	input             toccata_fit,

	// configuration-space access (one clock strobes), byte enables on
	// D31-D24 .. D7-D0 = offsets +0 .. +3 of the long word at addr
	input             z3space,         // $FF000000 (else $00E80000)
	input      [15:2] addr,
	input             wr,
	input       [3:0] be,
	input      [31:0] wdata,
	output     [31:0] rdata,

	// results
	output reg        z3ram256_ena,
	output reg  [3:0] z3ram256_base,   // A31-A28
	output reg        z3ram128_ena,
	output reg  [4:0] z3ram128_base,   // A31-A27
	output reg        rtg_ena,
	output reg  [7:0] rtg_base,        // A31-A24
	output reg        a2065_ena,
	output reg  [7:0] a2065_base,      // A23-A16
	output reg        toccata_ena,
	output reg  [7:0] toccata_base     // A23-A16
);

localparam B_Z3R256 = 3'd0, B_Z3R128 = 3'd1, B_RTG = 3'd2, B_A2065 = 3'd3, B_TOCCATA = 3'd4, B_NONE = 3'd7;

// boards still waiting for configuration
reg  [4:0] pend;
wire [4:0] fit = {toccata_fit, a2065_fit, rtg_fit, z3ram128_fit, z3ram256_fit};

reg [2:0] cur;
always @(*) begin
	cur = B_NONE;
	for (int i = 4; i >= 0; i--) if (pend[i]) cur = 3'(i);
end

// the configuration ROM nibble n (0..63) of board b, as the CPU reads it
function automatic [3:0] nib(input [2:0] b, input [5:0] n);
	nib = 4'b1111;                        // inverted registers read 0
	case (b)
		B_Z3R256, B_Z3R128:
			case (n)
				6'h00: nib = 4'b1010;          // Zorro III, link into the memory list, no ROM
				6'h01: nib = (b == B_Z3R256) ? 4'b0100 : 4'b0011;   // 256 MB / 128 MB (extended sizes)
				6'h02: nib = 4'b1110;          // product $10
				6'h04: nib = 4'b0000;          // flags: memory space, no shut-up, extended size, Zorro III
				6'h08: nib = 4'b1110;          // manufacturer $139C
				6'h09: nib = 4'b1100;
				6'h0A: nib = 4'b0110;
				6'h0B: nib = 4'b0011;
				6'h13: nib = (b == B_Z3R256) ? 4'b1110 : 4'b1101;   // serial 1 / 2
				default: ;
			endcase
		B_RTG:
			case (n)
				6'h00: nib = 4'b1000;          // Zorro III, device memory, no ROM
				6'h01: nib = 4'b0000;          // 16 MB (extended size code 0)
				6'h02: nib = 4'b1100;          // product $30
				6'h04: nib = 4'b0000;          // flags: memory space, no shut-up, extended size, Zorro III
				6'h08: nib = 4'b1110;          // manufacturer $139C
				6'h09: nib = 4'b1100;
				6'h0A: nib = 4'b0110;
				6'h0B: nib = 4'b0011;
				default: ;
			endcase
		B_A2065:
			case (n)
				6'h00: nib = 4'b1100;          // Zorro II, no memory list, no ROM
				6'h01: nib = 4'b0001;          // 64 KB
				6'h02: nib = 4'b1000;          // product $70
				6'h09: nib = 4'b1101;          // manufacturer $0202
				6'h0B: nib = 4'b1101;
				default: ;
			endcase
		B_TOCCATA:
			case (n)
				6'h00: nib = 4'b1100;          // Zorro II, no memory list, no ROM
				6'h01: nib = 4'b0001;          // 64 KB
				6'h03: nib = 4'b0011;          // product $0C
				6'h08: nib = 4'b1011;          // manufacturer $4754
				6'h09: nib = 4'b1000;
				6'h0A: nib = 4'b1010;
				6'h0B: nib = 4'b1011;
				default: ;
			endcase
		default: nib = 4'b0000;
	endcase
endfunction

// the Zorro II-layout byte at offset k
function automatic [7:0] zbyte(input [2:0] b, input [7:0] k);
	if (b == B_NONE || k[0] || k[7]) zbyte = 8'h00;
	else                             zbyte = {nib(b, k[6:1]), 4'b0000};
endfunction

// the offset in the Zorro II layout of byte lane i of this access
function automatic [7:0] lane_k(input z3, input [15:2] a, input [1:0] i);
	logic [15:0] x;
	x = {a, i};
	if (z3) lane_k = x[7:0] + (x[8] ? 8'd2 : 8'd0);
	else    lane_k = x[7:0];
endfunction

wire [7:0] k0 = lane_k(z3space, addr, 2'd0);
wire [7:0] k1 = lane_k(z3space, addr, 2'd1);
wire [7:0] k2 = lane_k(z3space, addr, 2'd2);
wire [7:0] k3 = lane_k(z3space, addr, 2'd3);

assign rdata = {zbyte(cur, k0), zbyte(cur, k1), zbyte(cur, k2), zbyte(cur, k3)};

wire is_z3 = (cur == B_Z3R256) || (cur == B_Z3R128) || (cur == B_RTG);

// a byte written at Zorro II-layout offset k, from whichever lane holds it
reg       w48, w4a, w44, w45, w4c;
reg [7:0] d48, d4a, d44, d45;
always @(*) begin
	{w48, w4a, w44, w45, w4c} = 5'd0;
	{d48, d4a, d44, d45} = 32'd0;
	if (be[3]) begin if (k0 == 8'h48) begin w48 = 1; d48 = wdata[31:24]; end
	                 if (k0 == 8'h4A) begin w4a = 1; d4a = wdata[31:24]; end
	                 if (k0 == 8'h44) begin w44 = 1; d44 = wdata[31:24]; end
	                 if (k0 == 8'h45) begin w45 = 1; d45 = wdata[31:24]; end
	                 if (k0 == 8'h4C) w4c = 1; end
	if (be[2]) begin if (k1 == 8'h48) begin w48 = 1; d48 = wdata[23:16]; end
	                 if (k1 == 8'h4A) begin w4a = 1; d4a = wdata[23:16]; end
	                 if (k1 == 8'h44) begin w44 = 1; d44 = wdata[23:16]; end
	                 if (k1 == 8'h45) begin w45 = 1; d45 = wdata[23:16]; end
	                 if (k1 == 8'h4C) w4c = 1; end
	if (be[1]) begin if (k2 == 8'h48) begin w48 = 1; d48 = wdata[15:8]; end
	                 if (k2 == 8'h4A) begin w4a = 1; d4a = wdata[15:8]; end
	                 if (k2 == 8'h44) begin w44 = 1; d44 = wdata[15:8]; end
	                 if (k2 == 8'h45) begin w45 = 1; d45 = wdata[15:8]; end
	                 if (k2 == 8'h4C) w4c = 1; end
	if (be[0]) begin if (k3 == 8'h48) begin w48 = 1; d48 = wdata[7:0]; end
	                 if (k3 == 8'h4A) begin w4a = 1; d4a = wdata[7:0]; end
	                 if (k3 == 8'h44) begin w44 = 1; d44 = wdata[7:0]; end
	                 if (k3 == 8'h45) begin w45 = 1; d45 = wdata[7:0]; end
	                 if (k3 == 8'h4C) w4c = 1; end
end

reg [7:0] lo48;    // a Zorro III board's A23-A16, written to $48 before $44

always @(posedge clk) begin
	if (reset) begin
		pend         <= fit;
		lo48         <= 8'h00;
		z3ram256_ena <= 0;
		z3ram128_ena <= 0;
		rtg_ena      <= 0;
		a2065_ena    <= 0;
		toccata_ena  <= 0;
	end
	else if (wr && cur != B_NONE) begin
		if (w4c) pend[cur] <= 1'b0;
		else if (is_z3) begin
			if (w48) lo48 <= d48;
			if (w44) begin
				pend[cur] <= 1'b0;
				case (cur)
					B_Z3R256: begin z3ram256_ena <= 1; z3ram256_base <= d44[7:4]; end
					B_Z3R128: begin z3ram128_ena <= 1; z3ram128_base <= d44[7:3]; end
					default:  begin rtg_ena      <= 1; rtg_base      <= d44;      end
				endcase
			end
		end
		else if (w48) begin
			pend[cur] <= 1'b0;
			if (cur == B_A2065) begin a2065_ena <= 1; a2065_base <= d48; end
			else begin toccata_ena <= 1; toccata_base <= d48; end
		end
	end
end

endmodule
