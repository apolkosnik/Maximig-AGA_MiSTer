// The A2065's CMD ring (the real a2065_ddr3_mailbox) against a host model:
// DDR3 as an array, INT_STATE with the host's read index (bit 1: published).
// A host that stops reading: 256 commands go into the ring, the 257th waits
// (no entry the host has not read is written over) and goes in, in order,
// once the host has read some; the host reads every command once, in order.
// A host that never reads: the waiting command is dropped after the wait
// limit and counted in the write index's high half, nothing overwritten.
// A host without the read index (an older Main): as before, no waiting.
// (After an audit's probe, 2026-10-25: the 257th command overwrote the 1st.)
`timescale 1ns/1ps
module tb;
reg clk = 0;
always #5 clk = ~clk;

localparam [28:0] BASE = 29'h03FE0000;
localparam [28:0] A_WPTR = BASE + 29'h1001, A_CSR = BASE + 29'h1002, A_INT = BASE + 29'h1003, A_RING = BASE + 29'h1100;

reg         rst_n = 0, pending = 0;
reg  [15:0] data = 0;
wire        clear;
wire [28:0] addr;
wire [63:0] wd;
wire        rd, wr;
reg  [63:0] response = 0;
reg         valid = 0;

a2065_ddr3_mailbox #(.FULL_WAIT_BITS(12)) dut
(
	.clk(clk), .rst_n(rst_n), .cmd_pending(pending), .cmd_rap(7'd1), .cmd_data(data), .cmd_clear(clear),
	.csr0_out(), .csr1_out(), .csr2_out(), .csr3_out(), .a2065_int2(),
	.bram_req_valid(1'b0), .bram_req_addr(14'd0), .bram_req_wdata(16'd0), .bram_req_rw(1'b0), .bram_req_be(2'b11),
	.bram_req_ack(), .bram_resp_valid(), .bram_resp_data(),
	.avl_address(addr), .avl_burstcount(), .avl_read(rd), .avl_readdata(response), .avl_readdatavalid(valid),
	.avl_writedata(wd), .avl_byteenable(), .avl_write(wr), .avl_waitrequest(1'b0)
);

// the host: its read index and whether it publishes it
reg  [31:0] host_rd = 0;
reg         host_pub = 1;
reg  [63:0] ring [256];
reg  [63:0] wptr_word = 0;
reg  [31:0] lag_max = 0;
integer     overwrites = 0;
always @(posedge clk) begin
	valid    <= rd;
	response <= (addr == A_INT) ? {host_rd, 30'd0, host_pub, 1'b0} : 64'd0;
	if (rst_n && wr) begin
		if (addr >= A_RING && addr < A_RING + 256) begin
			// an entry the host has not read yet must not be written
			if (wptr_word[31:0] - host_rd >= 256) begin
				overwrites = overwrites + 1;
				$display("OVERWRITE: write index %0d, host read index %0d", wptr_word[31:0], host_rd);
			end
			ring[addr[7:0]] <= wd;
		end
		if (addr == A_WPTR) wptr_word <= wd;
	end
end

integer failures = 0, checks = 0;
task check(input bit ok, input string msg);
	checks = checks + 1;
	if (!ok) begin $display("CONTROL FAIL: %s", msg); failures = failures + 1; end
endtask

// one RDP write: the regfile's pending until the mailbox clears it; returns
// whether it was cleared within n clocks
task command(input [15:0] n, input integer limit, output bit done);
	integer i;
	@(negedge clk); data = n; pending = 1;
	done = 0;
	for (i = 0; i < limit && !done; i++) begin @(negedge clk); if (clear) done = 1; end
	if (done) begin
		pending = 0;
		while (clear) @(negedge clk);
		repeat (4) @(negedge clk);
	end
endtask

// the host reads k commands: each the next number, in order
integer expect_next = 0;
task host_read(input integer k);
	for (integer i = 0; i < k; i++) begin
		check(ring[host_rd[7:0]][23:8] == 16'(expect_next) && ring[host_rd[7:0]][0],
		      $sformatf("host reads command %0d at index %0d: %04h", expect_next, host_rd, ring[host_rd[7:0]][23:8]));
		expect_next = expect_next + 1;
		host_rd = host_rd + 1;
	end
endtask

bit done;
integer i;

initial begin
	repeat (5) @(negedge clk);
	rst_n = 1;
	repeat (200) @(negedge clk);           // the write index published, the host's index polled

	// a host that stops reading: 256 go in
	for (i = 0; i < 256; i++) begin
		command(16'(i), 2000, done);
		check(done, $sformatf("command %0d into a ring with room", i));
	end
	check(wptr_word[31:0] == 256, $sformatf("write index %0d after 256", wptr_word[31:0]));
	// the 257th waits while the ring is full (well within the wait limit)
	@(negedge clk); data = 16'd256; pending = 1;
	repeat (2000) @(negedge clk);
	check(!clear && wptr_word[31:0] == 256, "the 257th waits at a full ring");
	// the host reads 10: it goes in, at index 256
	host_read(10);
	for (i = 0; i < 2000 && !clear; i++) @(negedge clk);
	check(clear, "the 257th goes in once the host has read");
	pending = 0;
	while (clear) @(negedge clk);
	repeat (4) @(negedge clk);
	check(wptr_word[31:0] == 257, $sformatf("write index %0d after the 257th", wptr_word[31:0]));
	for (i = 257; i < 266; i++) begin
		command(16'(i), 2000, done);
		check(done, $sformatf("command %0d after the host read", i));
	end
	host_read(256);                        // all of them, in order
	check(expect_next == 266, $sformatf("the host read %0d commands", expect_next));
	check(overwrites == 0, $sformatf("%0d unread entries written over", overwrites));
	check(wptr_word[63:32] == 0, "nothing dropped");

	// a host that never reads: fill, then the next is dropped after the wait
	for (i = 266; i < 266 + 256; i++) command(16'(i), 2000, done);
	command(16'hBEEF, 3 * 4096 + 2000, done);
	check(done, "a command at a full ring the host never drains is completed after the wait limit");
	check(wptr_word[63:32] == 1, $sformatf("dropped commands counted: %0d", wptr_word[63:32]));
	check(wptr_word[31:0] == 266 + 256, $sformatf("write index %0d: the dropped command has no entry", wptr_word[31:0]));
	check(overwrites == 0, $sformatf("%0d unread entries written over", overwrites));
	host_read(256);
	command(16'(266 + 256), 2000, done);   // after the drain the ring takes commands again
	check(done, "a command after the host drained");
	host_read(1);

	// a host without the read index (an older Main): no waiting
	host_pub = 0;
	repeat (300) @(negedge clk);
	for (i = 0; i < 300; i++) begin
		command(16'h4000 + 16'(i), 2000, done);
		if (!done) break;
	end
	check(done, "without the host's read index, commands are never held");

	if (failures == 0) $display("PASS: %0d checks, the CMD ring at a full host", checks);
	else               $display("FAIL: %0d of %0d", failures, checks);
	$finish;
end
endmodule
