// Copyright 2020
//
// This file is part of Minimig
//
// Minimig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// Minimig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http:// www.gnu.org/licenses/>.
//
//
//----------------------------------------------------------------------------------
//----------------------------------------------------------------------------------  
// REGISTER MAP
// B80100:B80101 :  8:0 : ADDR[24:16]
// B80102:B80103 : 15:0 : ADDR[15:0]
// B80104:B80105 : 5:0  : FORMAT[5:0]
// B80106:B80107 :    0 : ENABLE
// B80108:B80109 : 11:0 : HSIZE
// B8010A:B8010B : 11:0 : VSIZE
// B8010C:B8010D : 13:0 : STRIDE
// B8010E:B8010F :  7:0 : ID = 50 / VERSION = 01

// B80400..B807FF CLUT : 256 * 32bits 00 / RR / GG / BB

module rtg
(
	input             clk,           // clock
	input             aen,           // adress enable
	input             rd,            // read enable
	input             wr,            // write enable
	input             reset,         // reset
	input      [11:1] rs,            // register select (address)
	output            ready,

	input      [15:0] data_in,       // bus data in
	input       [1:0] be,            // byte enables: D15-D8, D7-D0
	output     [15:0] data_out,      // bus data out

	output reg        ena,
	output reg [11:0] hsize,
	output reg [11:0] vsize,
	output reg [4:0]  format,
	output reg [31:0] base,
	output reg [13:0] stride,
	output            pal_clk,
	output     [23:0] pal_dw,
	input      [23:0] pal_dr,
	output     [7:0]  pal_a,
	output            pal_wr
);

wire r_en  = aen && (rs[11:4]  == 'h10);
wire r_pal = aen && (rs[11:10] == 1);

// a register write keeps the bytes it does not enable
function [15:0] merge;
	input [15:0] old;
	begin
		merge = {be[1] ? data_in[15:8] : old[15:8], be[0] ? data_in[7:0] : old[7:0]};
	end
endfunction

// writing of output port
always @(posedge clk) begin
	if (reset) ena<=0;
	else if(wr) begin
		if(r_en) begin
			case(rs[3:1])
				0: base[31:16] <= merge(base[31:16]);
				1: base[15:0]  <= merge(base[15:0]);
				2: format      <= merge({11'd0, format}) & 16'h001F;
				3: ena         <= be[0] ? data_in[0] : ena;
				4: hsize       <= merge({4'd0, hsize}) & 16'h0FFF;
				5: vsize       <= merge({4'd0, vsize}) & 16'h0FFF;
				6: stride      <= merge({2'd0, stride}) & 16'h3FFF;
			endcase
		end
	end
end

reg [15:0] dout;
always @(posedge clk) begin
	dout <= 16'h0000;
	if(r_en) begin
		case(rs[3:1])
			0: dout <= base[31:16];
			1: dout <= base[15:0];
			2: dout <= format;
			3: dout <= ena;
			4: dout <= hsize;
			5: dout <= vsize;
			6: dout <= stride;
			7: dout <= 16'h5001;
		endcase
	end
	if (r_pal) dout <= rs[1] ? pal_dr[15:0] : pal_dr[23:16];
end

reg [2:0] rd_r;
always @(posedge clk) rd_r <= rd_ready ? 3'd0 : {rd_r[1:0],aen & rd};
wire rd_ready = r_pal ? rd_r[2] : rd_r[0];

// a CLUT write is a word of the addressed entry (00RR or GGBB): the entry is
// read first (pal_dr, as for a read) and the other components kept
reg [2:0] wr_r;
always @(posedge clk) wr_r <= wr_ready ? 3'd0 : {wr_r[1:0],aen & wr & r_pal};
wire wr_ready = wr_r[2];

assign pal_clk  = clk;
assign pal_a    = rs[9:2];
assign pal_wr   = wr_ready;
assign pal_dw   = rs[1] ? {pal_dr[23:16], be[1] ? data_in[15:8] : pal_dr[15:8], be[0] ? data_in[7:0] : pal_dr[7:0]}
                        : {be[0] ? data_in[7:0] : pal_dr[23:16], pal_dr[15:0]};

assign data_out = aen ? dout : 16'h0000;
assign ready    = aen & ((wr & !r_pal) | wr_ready | rd_ready);

endmodule
