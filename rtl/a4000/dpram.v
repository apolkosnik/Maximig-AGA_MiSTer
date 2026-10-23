// dpram: a true dual-port block RAM, one clock, both ports read and write,
// with the port names of Minimig's bram.vhd dpram so ide.v uses it
// unchanged.  As that altsyncram (BIDIR_DUAL_PORT, NEW_DATA_NO_NBE_READ):
// a port that writes reads the data it writes; a read of the address the
// other port writes in the same cycle gets the old data.  Written as
// Intel's single-clock true dual-port template, the form Quartus maps to
// an M10K (a read-before-write port it cannot: it builds the RAM from
// logic instead), and a plain array in simulation.

module dpram
#(
	parameter addr_width = 8,
	parameter data_width = 8
)
(
	input                       clock,

	input      [addr_width-1:0] address_a,
	input      [data_width-1:0] data_a,
	input                       wren_a,
	output reg [data_width-1:0] q_a,

	input      [addr_width-1:0] address_b,
	input      [data_width-1:0] data_b,
	input                       wren_b,
	output reg [data_width-1:0] q_b
);

reg [data_width-1:0] ram [0:(1<<addr_width)-1];

always @(posedge clock) begin
	if (wren_a) begin
		ram[address_a] <= data_a;
		q_a <= data_a;
	end
	else
		q_a <= ram[address_a];
end

always @(posedge clock) begin
	if (wren_b) begin
		ram[address_b] <= data_b;
		q_b <= data_b;
	end
	else
		q_b <= ram[address_b];
end

endmodule
