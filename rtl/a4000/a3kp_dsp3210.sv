//============================================================================
//  a3kp_dsp3210: the AT&T WE DSP3210 (WE DSP3210 Information Manual, AT&T,
//  September 1991), as the AA3000+ fits it
//
//  One instruction cycle is four states of CKI (ce), and every state carries
//  at most one memory access (7.1, Figure 7-1B):
//    state 0  X: the X operand of the DA instruction in O, or a CA load
//    state 1  Y: the Y operand of the DA instruction in O, or a CA store
//    state 2  I: the instruction fetch
//    state 3  Z: the Z write of the DA instruction in W
//  A state whose access goes to external memory lasts until the bus has
//  answered (external wait states).
//
//  An instruction passes through I (fetched), D (decoded; a CA instruction
//  executes here), O (a DA instruction's operands; a CA instruction's memory
//  access), M (multiply), A (accumulate; the accumulator and the DAU flags
//  set at the end of the cycle) and W (the Z write).  The register file
//  changes at the end of a cycle, in the order of the states: the O stage's
//  X and Y pointer updates, the D stage's CA register reads (they see those
//  two), the O stage's Z pointer update, a CA load into a register, the D
//  stage's CA result.  That gives the manual's latencies (4.4.2): a Z write
//  is seen four instructions later; an accumulator is a multiplier input
//  three instructions after it is computed and an adder input in the next
//  one; a branch has one latent instruction; a DAU condition tested by a CA
//  instruction is the one of four instructions before; a register loaded
//  from memory is not yet there for the next instruction (restriction 3).
//
//  Memories: RAM1 and RAM0 (1K x 32 each), the boot ROM (256 words) and the
//  MMIO registers on chip; external memory through the bus port (the DSP
//  master of a3kp_lbarb).  pcw[10] selects the map (3.4): Computer mode puts
//  the on-chip resources at 0x00000000-0x0000FFFF, Processor mode at
//  0x50030000-0x5003FFFF.  Big-endian byte order only (pcw[8] = 1, as the
//  AA3000 straps it).
//
//  Exceptions (7.5): interrupts by the continuation model -- the shadow
//  registers (pcsh, the instruction shadow, a0-a3, dauc, ps, ctr, the DO
//  loop), "goto evtp+8N; nop" -- and ireturn; errors by the abort model --
//  "call evtp+8N (r20); nop" -- with the error levels, sftrst and the double
//  error (the processor stops, IACK0 and IACK1 both up); reset as vector 0.
//  waiti, do and dolock (doblock runs as do: the AA3000's logic never answers
//  a burst, and software must not use it).
//
//  Not here yet: the serial I/O's shifting and its DMA (the MMIO registers
//  are), the timer's BIO1 output.
//============================================================================

module a3kp_dsp3210
import a3kp_dsp_pkg::*;
(
	input             clk,
	input             ce,             // CKI: one state
	input             reset,          // RESTN asserted

	// the bus: one access a handshake (toggle req; ack toggles back)
	output reg        m_req = 1'b0,
	input             m_ack,
	output reg [31:2] m_addr,
	output reg  [3:0] m_be,
	output reg        m_we,
	output reg [31:0] m_wdata,
	input      [31:0] m_rdata,
	input             m_berr,
	output            m_hold,         // the DSP wants the bus between its accesses

	// interrupts
	input             ir0_n,
	input             ir1_n,
	output            iack0,
	output            iack1,

	// BIO
	input       [7:0] bio_in,
	output      [7:0] bio_out,
	output      [7:0] bio_oe,

	// observation
	output     [31:0] dbg_pc,
	output reg        dbg_retire = 1'b0,
	output            dbg_halted
);

`include "a3kp_dsp_rom.svh"

//----------------------------------------------------------------------------
// register codes (Table 10-2): r0-r14 0-14, pc 15, r15-r19 17-21, -n 22,
// +n 23, r20-r22 24-26, pcsh 30
//----------------------------------------------------------------------------
localparam [4:0] R_PC = 5'd15, R_MN = 5'd22, R_PN = 5'd23, R_SP = 5'd25, R_EVTP = 5'd26, R_PCSH = 5'd30;

reg [31:0] pcsh = 32'd0;            // (the register file: a3kp_dsp_rf, below)

//----------------------------------------------------------------------------
// I/O registers (ior0 ps, ior8 emr, ior10 spc, ior12 pcw, ior14 dauc, ior15 ctr)
//----------------------------------------------------------------------------
reg  [3:0] cfl = 4'd0;              // CAU {n, z, v, c}
dflags_t   dfl = '{default: 1'b0};  // DAU N Z V U
reg [15:0] emr = 16'd0;
reg [15:0] pcw = 16'h0F8F;
reg  [7:0] dauc = 8'd0;
reg  [5:0] ctr = 6'd0;
reg [39:0] acc [4];

// MMIO (Figure 3-5)
reg  [7:0] tcon = 8'd0;
reg [31:0] tcount = 32'hFFFFFFFF;
reg [31:0] tinit = 32'hFFFFFFFF;
reg  [1:0] tpre = 2'd0;
reg  [7:0] bioc = 8'd0;
reg  [7:0] bio_q = 8'd0;
reg [31:0] ioc = 32'd0, idp = 32'd0, odp = 32'd0, ibuf = 32'd0, obuf = 32'd0;
reg [15:0] icnt = 16'd0, ocnt = 16'd0;
reg  [7:0] dmacr = 8'd0;
reg        ibf = 1'b0, obe = 1'b1;

assign bio_out = bio_q;
assign bio_oe  = bioc;

wire cmode = pcw[10];

// ps (Table 10-4): n z v c N Z U V ibf obe sy fb ir0 ir1
wire [15:0] ps = {2'b00, ir1_n, ir0_n, 1'b0, 1'b0, obe, ibf,
                  dfl.v, dfl.u, dfl.z, dfl.n, cfl[0], cfl[1], cfl[2], cfl[3]};

//----------------------------------------------------------------------------
// the memory map
//----------------------------------------------------------------------------
localparam [1:0] MT_RAM = 2'd0, MT_ROM = 2'd1, MT_MMIO = 2'd2, MT_EXT = 2'd3;

function automatic [1:0] mtype(input [31:0] a, input cm);
	logic on;
	on = cm ? (a[31:16] == 16'h0000) : (a[31:16] == 16'h5003);
	if (!on)                return MT_EXT;
	if (a[15:13] == 3'b111) return MT_RAM;          // RAM1 0xE000-0xEFFF, RAM0 0xF000-0xFFFF
	if (a[15:10] == 6'd0)   return MT_ROM;          // 0x0000-0x03FF
	return MT_MMIO;                                 // 0x0400-0x07FF (the reserved space reads 0)
endfunction

// big-endian lanes: byte enables and lane data of an access
function automatic [3:0] be_of(input [1:0] sz, input [1:0] a);
	case (sz)
		2'd0:    be_of = 4'b1000 >> a;
		2'd1:    be_of = a[1] ? 4'b0011 : 4'b1100;
		default: be_of = 4'b1111;
	endcase
endfunction

function automatic [31:0] lanes(input [1:0] sz, input [31:0] v);
	case (sz)
		2'd0:    lanes = {4{v[7:0]}};
		2'd1:    lanes = {2{v[15:0]}};
		default: lanes = v;
	endcase
endfunction

//----------------------------------------------------------------------------
// pipeline registers
//----------------------------------------------------------------------------
// D
reg        d_v = 1'b0;
reg [31:0] d_ir;
reg [31:0] d_pc;
reg        d_waiti_hold = 1'b0;     // D holds the instruction after waiti

// O
localparam [2:0] O_NONE = 3'd0, O_DA = 3'd1, O_LD = 3'd2, O_ST = 3'd3, O_LDIO = 3'd4;
reg  [2:0] o_k = O_NONE;
reg [31:0] o_ir;
reg [31:0] o_addr;                  // a CA access's address
reg  [2:0] o_w;                     // its W field
reg  [4:0] o_reg;                   // the CAU register / I/O register it loads
reg [31:0] o_sd;                    // a store's data
reg        o_nopint;                // (the exception's injected nop: the shadow copy)

// M, A: a DA instruction with its operands
typedef struct packed {
	logic        v;
	logic [31:0] ir;
	logic [39:0] x;             // the X operand (32-bit words as w40(w), accumulators 40 bits)
	logic [39:0] y;
	logic [31:0] yraw;          // Y as read (a tap writes it; the special functions read it)
	logic        yacc;          // Y is an accumulator
	logic [39:0] mop;           // class 1: the multiplier's M operand (an accumulator read in O, or a constant)
	logic [31:0] za;            // the Z address
	logic        zw;            // a Z write
	logic        ni;            // the exception's injected nop
	logic  [6:0] dc;            // dauc as the instruction left O (a dauc write affects the following instructions)
} dau_t;
dau_t m_s = '0, a_s = '0;
dprod_t m_p;                         // the M stage's product, into A

// W
reg        w_v = 1'b0;
reg [31:0] w_a;
reg [31:0] w_d;
reg  [1:0] w_sz;

//----------------------------------------------------------------------------
// exceptions, interrupts, loops
//----------------------------------------------------------------------------
reg  [1:0] level = 2'd0;            // 0 base, 1 interrupt, 2 error, 3 double error
reg        err_nm = 1'b0;           // the error level is a non-maskable error's
reg        halted = 1'b0;
reg        waiting = 1'b0;          // waiti: no fetch, D holds
reg  [1:0] inj = 2'd0;              // injected instructions still to come (the branch, the nop)
reg [31:0] inj_ir;
reg [31:0] inj_pc;
reg        irsh_v = 1'b0;           // the next D comes from the instruction shadow
reg [31:0] irsh, irsh_pc;
reg        irsh_has = 1'b0;         // the shadow holds an instruction (else the return just fetches pcsh)
reg        noint = 1'b0;            // the instruction just executed locks out an interrupt
reg        ir0_d = 1'b1, ir1_d = 1'b1;
reg        ir0_p = 1'b0, ir1_p = 1'b0, tmr_p = 1'b0;
reg  [1:0] iack_p = 2'b00;
reg  [3:0] iack_cnt = 4'd0;
reg  [2:0] shadow_cnt = 3'd0;       // cycles until the interrupt's shadow copy

reg [39:0] sh_acc [4];
reg  [7:0] sh_dauc;
reg  [5:0] sh_ctr;
reg  [3:0] sh_cfl;
dflags_t   sh_dfl;
reg        sh_lp_on, sh_lp_lock;
reg [31:0] sh_lp_start, sh_lp_end;
reg [10:0] sh_lp_cnt;

reg        lp_on = 1'b0;
reg        lp_lock = 1'b0;          // dolock: no interrupts
reg [31:0] lp_start, lp_end;
reg [10:0] lp_cnt;

assign dbg_halted = halted;
assign dbg_pc     = d_pc;

assign iack0 = (level == 2'd3) || (emr[0] ? level[0] : iack_p[0]);
assign iack1 = (level == 2'd3) || (emr[0] ? level[1] : iack_p[1]);

//----------------------------------------------------------------------------
// the state sequencer: the cycle's four memory slots
//----------------------------------------------------------------------------
reg  [1:0] st = 2'd0;
reg [31:0] fpc = 32'd0;             // the next instruction fetch's address
reg        pend = 1'b0;             // an external access is out
reg  [1:0] prev_t;                  // the memory type of the last access (its data follows)
reg        prev_v = 1'b0;
reg [31:0] ext_q, rom_q, mmio_q;
reg [31:0] xq, yq;                  // the X and Y slots' data
reg        berr = 1'b0;             // a bus error this cycle
reg        aerr = 1'b0;             // an address error this cycle

// on-chip RAM: 2K words (RAM1 0xE000, RAM0 0xF000), one access a state
reg  [3:0][7:0] ram [0:2047];         // RAM1 (0xE000) and RAM0 (0xF000): byte lanes, M10K
reg [31:0] ram_q;

wire [31:0] prev_q = (prev_t == MT_RAM) ? ram_q : (prev_t == MT_ROM) ? rom_q :
                     (prev_t == MT_MMIO) ? mmio_q : ext_q;

assign m_hold = !reset && !halted && !waiting && mtype(fpc, cmode) == MT_EXT;

//----------------------------------------------------------------------------
// the register file and the DA pointers
//----------------------------------------------------------------------------
// the DA instruction in O: its pointer fields
wire [6:0] ox = o_ir[20:14], oy = o_ir[13:7], oz = o_ir[6:0];
wire       o_da = (o_k == O_DA);
wire       o_sf = o_da && (o_ir[31:27] == 5'b01111);       // a special function: no X

// operand sizes: ic reads a byte, float16 a half; oc writes a byte, int16 a half
function automatic [1:0] y_size(input [31:0] ir);
	if (ir[31:27] == 5'b01111 && ir[26:23] == 4'd0) return 2'd0;   // ic
	if (ir[31:27] == 5'b01111 && ir[26:23] == 4'd2) return 2'd1;   // float16
	return 2'd2;
endfunction
function automatic [1:0] z_size(input [31:0] ir);
	if (ir[31:27] == 5'b01111 && ir[26:23] == 4'd1) return 2'd0;   // oc
	if (ir[31:27] == 5'b01111 && ir[26:23] == 4'd3) return 2'd1;   // int16
	return 2'd2;
endfunction
function automatic [31:0] inc_of(input [1:0] sz);
	inc_of = (sz == 2'd0) ? 32'd1 : (sz == 2'd1) ? 32'd2 : 32'd4;
endfunction

// a DA pointer field's address and its updated pointer
function automatic [31:0] pm_new(input [31:0] p, input [2:0] i, input [1:0] sz, input [31:0] r15_19);
	case (i)
		3'd0:    pm_new = p;
		3'd6:    pm_new = p - inc_of(sz);
		3'd7:    pm_new = p + inc_of(sz);
		default: pm_new = p + r15_19;
	endcase
endfunction

// the register file's read ports: D's three (rq[0-2]), the DA pointer and
// its r15-r19 increment (rq[3-4])
wire  [4:0] rq_a [5];
wire [31:0] rq [5];

// a register by code from its read port's word (r0 reads 0, pcsh its own register)
function automatic [31:0] rf_rd(input [4:0] c, input [31:0] q);
	case (c)
		5'd0:    rf_rd = 32'd0;
		R_PCSH:  rf_rd = pcsh;
		default: rf_rd = q;
	endcase
endfunction

wire        ox_mem = o_da && !o_sf && ox[6:3] != 4'd0;
wire        oy_mem = o_da && oy[6:3] != 4'd0;
wire        oz_mem = o_da && oz[6:3] != 4'd0;

// the DA instruction's pointer in this state -- X (0), Y (1), Z (2), the
// CAU's one address add a state (8.1, Figure 8-5): its update is written
// as the state ends, so the next state and D (state 3) see it
wire  [6:0] pf     = (st == 2'd0) ? ox : (st == 2'd1) ? oy : oz;
wire        pf_mem = (st == 2'd0) ? ox_mem : (st == 2'd1) ? oy_mem : (st == 2'd2) ? oz_mem : 1'b0;
wire  [1:0] pf_sz  = (st == 2'd0) ? 2'd2 : (st == 2'd1) ? y_size(o_ir) : z_size(o_ir);
assign      rq_a[3] = {1'b0, pf[6:3]};
assign      rq_a[4] = {2'b10, pf[2:0]};
wire [31:0] pf_p   = rf_rd(rq_a[3], rq[3]);
wire [31:0] pf_new = pm_new(pf_p, pf[2:0], pf_sz, rf_rd(rq_a[4], rq[4]));
reg   [1:0] y_lo;                   // Y's byte offset (state 1)
reg  [31:0] z_addr;                 // Z's address (state 2)

//----------------------------------------------------------------------------
// D: the decode and the CA execution (combinational on the D view)
//----------------------------------------------------------------------------
wire [31:0] dpc8 = d_pc + 32'd8;    // "pc" as an operand: the instruction's address + 8

function automatic [31:0] dget(input [4:0] c, input [31:0] q);
	if (c == R_PC) return dpc8;
	return rf_rd(c, q);
endfunction

// D's three register reads: rS1 / rP (bits 15-11), rS2 / rI / rM (bits
// 4-0; the loop's rM at 25-21), rB / rS / rD / rH (bits 20-16)
assign      rq_a[0] = d_ir[15:11];
assign      rq_a[1] = (d_ir[31:26] == 6'b000011) ? d_ir[25:21] : d_ir[4:0];
assign      rq_a[2] = d_ir[20:16];
wire [31:0] dp_a = dget(rq_a[0], rq[0]);
wire [31:0] dp_b = dget(rq_a[1], rq[1]);
wire [31:0] dp_c = dget(rq_a[2], rq[2]);

function automatic logic illegal(input [5:0] op);
	case (op)
		6'h00, 6'h01, 6'h02, 6'h0F, 6'h16, 6'h17, 6'h22: illegal = 1'b1;
		default: illegal = 1'b0;
	endcase
endfunction

function automatic logic cond_true(input [5:0] c, input [3:0] cf, input dflags_t df,
                                   input i_ibf, input i_obe, input i_ir0, input i_ir1);
	logic n, z, v, cy, r;
	n = cf[3]; z = cf[2]; v = cf[1]; cy = cf[0];
	case (c[5:1])
		5'd0:  r = 1'b1;
		5'd1:  r = n;
		5'd2:  r = z;
		5'd3:  r = v;
		5'd4:  r = cy;
		5'd5:  r = n ^ v;
		5'd6:  r = z | (n ^ v);
		5'd7:  r = cy | z;
		5'd8:  r = df.u;
		5'd9:  r = df.n;
		5'd10: r = df.z;
		5'd11: r = df.v;
		5'd12: r = df.n | df.z;
		5'd16: r = i_ibf;
		5'd17: r = i_obe;
		5'd20: r = 1'b0;          // sy
		5'd21: r = 1'b0;          // fb
		5'd22: r = i_ir0;
		5'd23: r = i_ir1;
		default: r = 1'b0;
	endcase
	cond_true = (r == c[0]);
endfunction

// the CAU's ALU (Table 10-2's F; 4.3.2, Table 4-1's flag rules): {n,z,v,c,result}.
// One adder (a + b, b - a, a - b, the carry-reverse add on bit-reversed
// operands; a 16-bit operation's carry and overflow from bits 16 and 15)
// and one shifter (right; left on the reversed word)
function automatic [31:0] rev32(input [31:0] x);
	for (int i = 0; i < 32; i++) rev32[i] = x[31 - i];
endfunction

function automatic [35:0] alu(input [3:0] f, input [31:0] a, input [31:0] b, input l, input [3:0] cfi);
	logic [31:0] r, x, y0, y, v, sx, sz, ra, rb, ta, tb, ts;
	logic [63:0] sw;
	logic n, z, ov, c, sub, rv, left, ar, c16;
	logic [32:0] s;
	logic  [4:0] sn;
	n = 1'b0; z = 1'b0; ov = 1'b0; c = 1'b0; r = 32'd0;
	// the adder
	sub = (f == 4'd2) || (f == 4'd4) || (f == 4'd7);
	rv  = (f == 4'd3);
	ta  = rev32(a);
	tb  = rev32(b);
	ra  = l ? ta : {16'd0, ta[31:16]};
	rb  = l ? tb : {16'd0, tb[31:16]};
	x   = rv ? ra : (f == 4'd2) ? b : a;
	y0  = rv ? rb : (f == 4'd2) ? a : b;
	y   = sub ? ~y0 : y0;
	s   = {1'b0, x} + {1'b0, y} + {32'd0, sub};
	c16 = s[16] ^ x[16] ^ y[16];                    // the carry into bit 16
	// the shifter
	left = (f == 4'd1);
	ar   = (f == 4'd13);
	v    = l ? a : {{16{ar & a[15]}}, a[15:0]};
	sn   = l ? b[4:0] : {1'b0, b[3:0]};
	sx   = left ? rev32(v) : v;
	sw   = {{32{ar & v[31]}}, sx} >> sn;
	sz   = left ? rev32(sw[31:0]) : sw[31:0];
	case (f)
		4'd0, 4'd2, 4'd4, 4'd7: begin                 // a + b; b - a (2), a - b (4, 7)
			r  = s[31:0];
			c  = (l ? s[32] : c16) ^ sub;               // (a subtraction's borrow)
			ov = sub ? (l ? (x[31] != y0[31] && r[31] != x[31]) : (x[15] != y0[15] && s[15] != x[15]))
			         : (l ? (x[31] == y0[31] && r[31] != x[31]) : (x[15] == y0[15] && s[15] != x[15]));
		end
		4'd3: begin                                     // # carry-reverse add
			ts = rev32(s[31:0]);
			r  = l ? ts : {16'd0, ts[31:16]};
			c = l ? s[32] : s[16];
		end
		4'd1, 4'd12, 4'd13: r = sz;
		4'd6:  r = a & ~b;
		4'd8:  r = a ^ b;
		4'd10: r = a | b;
		4'd14, 4'd15: r = a & b;
		4'd9: begin                                   // >>>1: rotate right through carry
			r = l ? {cfi[0], a[31:1]} : {16'd0, cfi[0], a[15:1]};
			c = a[0];
		end
		4'd11: begin                                  // <<<1: rotate left through carry
			r  = l ? {a[30:0], cfi[0]} : {16'd0, a[14:0], cfi[0]};
			c  = l ? a[31] : a[15];
			ov = l ? (a[31] ^ a[30]) : (a[15] ^ a[14]);
		end
		default: r = 32'd0;
	endcase
	if (!l) r[31:16] = {16{r[15]}};
	n = l ? r[31] : r[15];
	z = l ? (r == 32'd0) : (r[15:0] == 16'd0);
	alu = {n, z, ov, c, r};
endfunction

// synthesis translate_off
// (the ALU as it was, every operation its own adder or shifter: the
// reference the shared one is checked against at start-up)
function automatic [35:0] alu_ref(input [3:0] f, input [31:0] a, input [31:0] b, input l, input [3:0] cfi);
	logic [31:0] r;
	logic n, z, v, c;
	logic [32:0] s;
	logic [16:0] s16;
	n = 1'b0; z = 1'b0; v = 1'b0; c = 1'b0; r = 32'd0;
	case (f)
		4'd0: begin                                   // a + b
			s   = {1'b0, a} + {1'b0, b};
			s16 = {1'b0, a[15:0]} + {1'b0, b[15:0]};
			r   = s[31:0];
			c   = l ? s[32] : s16[16];
			v   = l ? (a[31] == b[31] && r[31] != a[31]) : (a[15] == b[15] && s16[15] != a[15]);
		end
		4'd2, 4'd4, 4'd7: begin                       // b - a (2), a - b (4, 7)
			logic [31:0] p, q;
			p   = (f == 4'd2) ? b : a;
			q   = (f == 4'd2) ? a : b;
			s   = {1'b0, p} - {1'b0, q};
			s16 = {1'b0, p[15:0]} - {1'b0, q[15:0]};
			r   = s[31:0];
			c   = l ? s[32] : s16[16];
			v   = l ? (p[31] != q[31] && r[31] != p[31]) : (p[15] != q[15] && s16[15] != p[15]);
		end
		4'd3: begin                                   // # carry-reverse add
			logic [31:0] ra, rb;
			for (int i = 0; i < 32; i++) begin ra[i] = a[31 - i]; rb[i] = b[31 - i]; end
			if (l) begin
				s = {1'b0, ra} + {1'b0, rb};
				for (int i = 0; i < 32; i++) r[i] = s[31 - i];
				c = s[32];
			end
			else begin
				logic [15:0] ra16, rb16;
				for (int i = 0; i < 16; i++) begin ra16[i] = a[15 - i]; rb16[i] = b[15 - i]; end
				s16 = {1'b0, ra16} + {1'b0, rb16};
				for (int i = 0; i < 16; i++) r[i] = s16[15 - i];
				c = s16[16];
			end
		end
		4'd1:  r = l ? (a << b[4:0]) : {16'd0, a[15:0] << b[3:0]};
		4'd12: r = l ? (a >> b[4:0]) : {16'd0, a[15:0] >> b[3:0]};
		4'd13: r = l ? 32'($signed(a) >>> b[4:0]) : {16'd0, 16'($signed(a[15:0]) >>> b[3:0])};
		4'd6:  r = a & ~b;
		4'd8:  r = a ^ b;
		4'd10: r = a | b;
		4'd14, 4'd15: r = a & b;
		4'd9: begin                                   // >>>1: rotate right through carry
			r = l ? {cfi[0], a[31:1]} : {16'd0, cfi[0], a[15:1]};
			c = a[0];
		end
		4'd11: begin                                  // <<<1: rotate left through carry
			r = l ? {a[30:0], cfi[0]} : {16'd0, a[14:0], cfi[0]};
			c = l ? a[31] : a[15];
			v = l ? (a[31] ^ a[30]) : (a[15] ^ a[14]);
		end
		default: r = 32'd0;
	endcase
	if (!l) r[31:16] = {16{r[15]}};
	n = l ? r[31] : r[15];
	z = l ? (r == 32'd0) : (r[15:0] == 16'd0);
	alu_ref = {n, z, v, c, r};
endfunction
initial begin
	logic [31:0] ra_, rb_;
	logic [3:0]  rf_, rc_;
	logic        rl_;
	for (int i = 0; i < 1000000; i++) begin
		ra_ = $urandom; rb_ = $urandom; rf_ = 4'($urandom); rc_ = 4'($urandom); rl_ = 1'($urandom);
		if (i % 4 == 1) rb_ = {27'd0, 5'($urandom)};          // (shift counts)
		if (i % 8 == 3) ra_ = {16'($urandom), 16'h8000};
		if (alu(rf_, ra_, rb_, rl_, rc_) !== alu_ref(rf_, ra_, rb_, rl_, rc_)) begin
			$display("FAIL: dsp: ALU f %0d l %0d a %08X b %08X c %b: %09X, reference %09X", rf_, rl_, ra_, rb_, rc_,
			         alu(rf_, ra_, rb_, rl_, rc_), alu_ref(rf_, ra_, rb_, rl_, rc_));
			$finish;
		end
	end
end
// synthesis translate_on

// the ALU's operands, one ALU for D's three arithmetic forms: rD = rS3 + N,
// [if (COND)] rD = rS1 F rS2 (rS2 -n / +n: by 1, the stack pointer by 4),
// rD = rD F N
logic  [3:0] au_f;
logic [31:0] au_a, au_b;
always @(*) begin
	au_f = 4'd0;
	au_a = dp_c;
	au_b = {{16{d_ir[15]}}, d_ir[15:0]};
	if (d_ir[30:25] == 6'b001100) begin
		au_f = d_ir[24:21];
		au_a = dp_a;
		if (d_ir[4:0] == R_MN || d_ir[4:0] == R_PN) begin
			au_b = (d_ir[20:16] == R_SP && d_ir[15:11] == R_SP) ? 32'd4 : 32'd1;
			if (d_ir[4:0] == R_MN && au_f == 4'd0) au_f = 4'd4;
		end
		else au_b = dp_b;
	end
	else if (d_ir[30:25] == 6'b001101) begin
		au_f = d_ir[24:21];
		if (au_f == 4'd1 || au_f == 4'd12 || au_f == 4'd13) au_b = {27'd0, d_ir[4:0]};
	end
end
wire [35:0] au_res = alu(au_f, au_a, au_b, d_ir[31], cfl);

// a CA load's register value from the bytes read
function automatic [31:0] ld_ext(input [2:0] w, input [31:0] d, input [1:0] a);
	logic [7:0]  b;
	logic [15:0] h;
	b = d[31 - 8*a -: 8];
	h = a[1] ? d[15:0] : d[31:16];
	case (w)
		3'd0:    ld_ext = {24'd0, b};
		3'd1:    ld_ext = {{24{b[7]}}, b};
		3'd2:    ld_ext = {16'd0, h};
		3'd3:    ld_ext = {{16{h[15]}}, h};
		3'd4:    ld_ext = {16'd0, b, 8'd0};
		default: ld_ext = d;
	endcase
endfunction

function automatic [1:0] wsize(input [2:0] w);
	case (w)
		3'd0, 3'd1, 3'd4: wsize = 2'd0;
		3'd2, 3'd3:       wsize = 2'd1;
		default:          wsize = 2'd2;
	endcase
endfunction

// a store's data: the register's bits the size selects
function automatic [31:0] st_bits(input [2:0] w, input [31:0] v);
	case (w)
		3'd4:    st_bits = {24'd0, v[15:8]};          // hbyte: bits 15-8
		default: st_bits = v;
	endcase
endfunction

// an I/O register's value
function automatic [31:0] io_get(input [4:0] c);
	case (c)
		5'd0:    io_get = {16'd0, ps};
		5'd8:    io_get = {16'd0, emr};
		5'd12:   io_get = {16'd0, pcw};
		5'd14:   io_get = {24'd0, dauc};
		5'd15:   io_get = {26'd0, ctr};
		default: io_get = 32'd0;
	endcase
endfunction

// The D stage's decode: what it does at the end of the cycle
typedef struct packed {
	logic        wr;            // a CAU register result
	logic [4:0]  wr_c;
	logic [31:0] wr_v;
	logic        pm;            // a CA pointer update
	logic [4:0]  pm_c;
	logic [31:0] pm_v;
	logic        fl;            // the CAU flags set
	logic [3:0]  fl_v;
	logic        br;            // a branch (after the latent instruction)
	logic [31:0] br_t;
	logic        lnk;           // call: the link register
	logic [4:0]  lnk_c;
	logic [2:0]  ok;            // the O stage it starts (O_NONE, O_LD, O_ST, O_LDIO)
	logic [31:0] oa;
	logic [2:0]  ow;
	logic [4:0]  oreg;
	logic [31:0] osd;
	logic        io_wr;         // an I/O register written from a CAU register
	logic [4:0]  io_c;
	logic [31:0] io_v;
	logic [1:0]  io_sz;
	logic        lp;            // do
	logic [6:0]  lp_k;
	logic [10:0] lp_l;
	logic        lp_lk;
	logic        iret;
	logic        waiti;
	logic        sftrst;
	logic        noint;         // no interrupt after it
	logic        ill;           // illegal opcode
	logic        da;            // a DA instruction (to O)
} dres_t;

dres_t dx;
always @(*) begin
	logic [31:0] ir, a, b, nimm, r;
	logic [35:0] res;
	logic        l, ok_c;
	logic [4:0]  rd, rs1, rs2, rp, ri, rh;
	logic [3:0]  f;
	logic [1:0]  sz;
	logic [31:0] inc, p;
	a = 32'd0; b = 32'd0; r = 32'd0; res = 36'd0; ok_c = 1'b0;
	rd = 5'd0; rs1 = 5'd0; rs2 = 5'd0; rp = 5'd0; ri = 5'd0; rh = 5'd0; f = 4'd0;
	sz = 2'd0; inc = 32'd0; p = 32'd0;
	ir = d_ir;
	dx = '0;
	nimm = {{16{ir[15]}}, ir[15:0]};
	l = ir[31];
	if (!d_v || d_waiti_hold) begin
		// nothing
	end
	else if (illegal(ir[31:26])) dx.ill = 1'b1;
	else if (ir[31:29] != 3'b000 && !ir[31]) dx.da = 1'b1;             // DA classes 001-011
	else if (ir[31:27] == 5'b10000) begin
		// conditional branch, nop, ireturn, return
		if (ir == 32'h803E0000) dx.iret = 1'b1;
		else if (cond_true(ir[26:21], cfl, dfl, ibf, obe, ir0_n, ir1_n)) begin
			dx.br   = 1'b1;
			dx.br_t = dp_c + nimm;
		end
		dx.noint = (ir[26:21] != 6'd0);
	end
	else if (ir[31:26] == 6'b000011) begin
		// if (rM-- >= 0) goto rB+N
		a = dp_b;
		dx.wr   = 1'b1;
		dx.wr_c = ir[25:21];
		dx.wr_v = a - 32'd1;
		if (!a[31]) begin
			dx.br   = 1'b1;
			dx.br_t = dp_c + nimm;
		end
		dx.noint = 1'b1;
	end
	else if (ir[31:25] == 7'b1000110 || ir[31:25] == 7'b1000111) begin
		// do K, {L, rM}
		dx.lp    = 1'b1;
		dx.lp_k  = ir[17:11];
		r        = dp_b;
		dx.lp_l  = ir[25] ? r[10:0] : ir[10:0];
		dx.lp_lk = ir[24];
	end
	else if (ir[31:26] == 6'b000100) begin
		// call rB+N (rM)
		dx.br    = 1'b1;
		dx.br_t  = dp_c + nimm;
		dx.lnk   = 1'b1;
		dx.lnk_c = ir[25:21];
		dx.noint = 1'b1;
	end
	else if (ir[31:29] == 3'b101) begin
		// goto rB+M (24-bit)
		dx.br    = 1'b1;
		dx.br_t  = dp_c + {8'd0, ir[28:21], ir[15:0]};
		dx.noint = 1'b1;
	end
	else if (ir[31:29] == 3'b110) begin
		// rD = (ushort24) M
		dx.wr   = 1'b1;
		dx.wr_c = ir[20:16];
		dx.wr_v = {8'd0, ir[28:21], ir[15:0]};
	end
	else if (ir[31:29] == 3'b111) begin
		// call M (rM)
		dx.br    = 1'b1;
		dx.br_t  = {8'd0, ir[28:21], ir[15:0]};
		dx.lnk   = 1'b1;
		dx.lnk_c = ir[20:16];
		dx.noint = 1'b1;
	end
	else if (ir[31:26] == 6'b100100) begin
		// rD = rS <<| N
		r = dp_c | {ir[15:0], 16'd0};
		dx.wr   = 1'b1;
		dx.wr_c = ir[25:21];
		dx.wr_v = r;
		dx.fl   = 1'b1;
		dx.fl_v = {r[31], r == 32'd0, 2'b00};
	end
	else if (ir[30:26] == 5'b00101) begin
		// rD = rS3 + N (16/32)
		res = au_res;
		dx.wr   = 1'b1;
		dx.wr_c = ir[25:21];
		dx.wr_v = res[31:0];
		dx.fl   = 1'b1;
		dx.fl_v = res[35:32];
	end
	else if (ir[30:25] == 6'b001100) begin
		// [if (COND)] rD = rS1 F rS2
		f   = au_f;
		rd  = ir[20:16];
		rs1 = ir[15:11];
		rs2 = ir[4:0];
		// (rS2 as -n / +n of the stack pointer: not interruptible)
		if ((rs2 == R_MN || rs2 == R_PN) && rd == R_SP && rs1 == R_SP) dx.noint = 1'b1;
		if (cond_true(ir[10:5], cfl, dfl, ibf, obe, ir0_n, ir1_n)) begin
			res = au_res;
			dx.fl   = 1'b1;
			dx.fl_v = (f == 4'd0 || f == 4'd2 || f == 4'd4 || f == 4'd7 || f == 4'd11) ? res[35:32] :
			          (f == 4'd3 || f == 4'd9) ? {res[35:34], 1'b0, res[32]} : {res[35:34], 2'b00};
			if (f != 4'd7 && f != 4'd15) begin
				dx.wr   = 1'b1;
				dx.wr_c = rd;
				dx.wr_v = res[31:0];
			end
		end
	end
	else if (ir[30:25] == 6'b001101) begin
		// rD = rD F N (and rD - N, rD & N without a store)
		f  = au_f;
		rd = ir[20:16];
		res = au_res;
		dx.fl   = 1'b1;
		dx.fl_v = (f == 4'd0 || f == 4'd2 || f == 4'd4 || f == 4'd7) ? res[35:32] :
		          (f == 4'd3) ? {res[35:34], 1'b0, res[32]} : {res[35:34], 2'b00};
		if (f != 4'd7 && f != 4'd15) begin
			dx.wr   = 1'b1;
			dx.wr_c = rd;
			dx.wr_v = res[31:0];
		end
	end
	else if (ir[31:25] == 7'b0001110) begin
		// *L moves: rH = *L / *L = rH
		dx.oa = cmode ? {16'h0000, ir[15:0]} : {16'h5003, ir[15:0]};
		dx.ow = ir[23:21];
		if (ir[24]) begin
			dx.ok  = O_ST;
			dx.osd = st_bits(ir[23:21], dp_c);
		end
		else begin
			dx.ok   = O_LD;
			dx.oreg = ir[20:16];
			dx.noint = 1'b1;
		end
	end
	else if (ir[31:25] == 7'b1001110 && ir[10]) begin
		// rH = iorH / iorH = rH
		if (ir[24]) begin
			dx.io_wr = 1'b1;
			dx.io_c  = ir[4:0];
			dx.io_v  = dp_c;
			dx.io_sz = wsize(ir[23:21]);
			if (ir[4:0] == 5'd10) begin
				// spc: waiti (long), bkpt (short), sftrst (byte)
				dx.waiti  = (ir[23:21] == 3'd7);
				dx.sftrst = (ir[23:21] == 3'd0);
			end
		end
		else begin
			dx.wr   = 1'b1;
			dx.wr_c = ir[20:16];
			dx.wr_v = ld_ext(ir[23:21], io_get(ir[4:0]) << ((ir[23:21] == 3'd7) ? 0 : (wsize(ir[23:21]) == 2'd1) ? 16 : 24), 2'd0);
			dx.fl   = 1'b1;
			dx.fl_v = {dx.wr_v[31], dx.wr_v == 32'd0, 2'b00};
			dx.noint = 1'b1;
		end
	end
	else if (ir[31:25] == 7'b1001110 || ir[31:25] == 7'b1001111) begin
		// memory moves through a pointer: rH = *rP++rI, *rP++rI = rH;
		// iorH = *rP++rI, *rP++rI = iorH
		rp = ir[15:11];
		ri = ir[4:0];
		sz = (rp == R_SP) ? 2'd2 : wsize(ir[23:21]);
		inc = (ri == R_PN) ? inc_of(sz) : (ri == R_MN) ? -inc_of(sz) : dp_b;
		if (rp == R_SP && (ri == R_PN || ri == R_MN)) inc = (ri == R_PN) ? 32'd4 : -32'd4;
		p = dp_a;
		dx.oa   = p;
		dx.ow   = (rp == R_SP) ? 3'd7 : ir[23:21];
		dx.pm   = (ri != 5'd0);
		dx.pm_c = rp;
		dx.pm_v = p + inc;
		if (ir[25]) begin
			// the I/O register side
			if (ir[24]) begin
				dx.ok  = O_ST;
				dx.osd = io_get(ir[20:16]);
			end
			else begin
				dx.ok   = O_LDIO;
				dx.oreg = ir[20:16];
				dx.noint = 1'b1;
			end
		end
		else if (ir[24]) begin
			dx.ok  = O_ST;
			dx.osd = st_bits(ir[23:21], dp_c);
		end
		else begin
			dx.ok   = O_LD;
			dx.oreg = ir[20:16];
			dx.noint = 1'b1;
		end
	end
	else dx.ill = 1'b1;
end

//----------------------------------------------------------------------------
// the DAU: M (multiply) and A (accumulate / special function), on the
// stage registers (whole cycles for the arithmetic)
//----------------------------------------------------------------------------
// the class-1/2/3 operands
function automatic dfp_t const_m(input [2:0] mf);
	case (mf)
		3'd5:    const_m = unpack32(32'h00000080);     // 1.0
		default: const_m = DFP_ZERO;                   // 0.0 (4)
	endcase
endfunction

// M: the product
dprod_t m_prod;
always @(*) begin
	dfp_t px, py;
	logic [2:0] cls, mf;
	cls = m_s.ir[31:29];
	mf  = m_s.ir[28:26];
	px  = trunc24(unpack40(m_s.x));
	if (cls == 3'd1) begin
		// aN = ±Y ± M*X: the multiplier's M operand (DAU4: 1.0)
		py = (mf == 3'd6) ? unpack32(32'h00000080) : trunc24(unpack40(m_s.mop));
	end
	else py = trunc24(unpack40(m_s.y));
	m_prod = fmul(px, py);
end

// A: the adder (or the special function); its result, flags and Z data.
// The arithmetic shares one shifter over the cycle's first clocks (the A
// sequence, a_q: below): S0 the adder's alignment or the float-to-integer
// shift, S1 the normalizer or the integer's rounding and saturation; their
// results are registered (nr_q, nf_q, iv_q) and the cycle's last state
// waits for them.
dfp_t     a_res;
dflags_t  a_fl;
logic     a_fl_en;
logic     a_wr;                     // the accumulator is written
logic [39:0] a_wval;
logic [31:0] a_zd;                  // the Z data
logic [1:0]  a_zsz;
logic        a_zen;
logic        a_ov;                  // over/underflow (an exception if enabled)
logic        a_nan;
// the sequence's inputs: what is normalized (1 the multiply-accumulate's
// sum of a_aa and a_bb, 2 round()'s value, 3 an integer converted: a_nz),
// the float-to-integer conversion (a_f2i: oc, int16, int32)
logic  [1:0] a_nk;
dadd_t       a_aa, a_bb;
dsum_t       a_nz;
logic        a_f2i;
dfp_t        a_tx;
logic  [1:0] a_trnd;
logic  [5:0] a_tbits;
dfp_t        nr_q;
dflags_t     nf_q;
logic signed [32:0] iv_q;
always @(*) begin
	logic [2:0] cls, mf;
	logic [1:0] n;
	logic       ff, ss;
	dfp_t       s;
	dadd_t      aa, bb;
	logic [3:0] g;
	dfp_t       y;
	logic [31:0] yw, sw, cz;
	logic       c, cfe, cnan, cnq;
	logic [39:0] cv;
	dflags_t    cf;
	dsum_t      nz;                     // the normalizer's input
	logic [1:0] nk;                     // ... whose: 1 multiply-accumulate, 2 round, 3 a conversion
	dfp_t       nr;
	dflags_t    nf;
	logic [39:0] ya;
	s = DFP_ZERO; aa = '0; bb = '0; g = 4'd0; y = DFP_ZERO; yw = 32'd0; sw = 32'd0;
	c = 1'b0; cv = 40'd0; cz = 32'd0; cf = '0; cfe = 1'b0; cnan = 1'b0; cnq = 1'b0;
	nz = '0; nk = 2'd0; ya = 40'd0;
	a_f2i = 1'b0; a_tx = DFP_ZERO; a_trnd = 2'd0; a_tbits = 6'd32;
	cls = a_s.ir[31:29];
	mf  = a_s.ir[28:26];
	n   = a_s.ir[22:21];
	ff  = a_s.ir[24];
	ss  = a_s.ir[23];
	a_res   = DFP_ZERO;
	a_fl    = '0;
	a_fl_en = 1'b0;
	a_wr    = 1'b0;
	a_wval  = 40'd0;
	a_zd    = 32'd0;
	a_zsz   = 2'd2;
	a_zen   = a_s.zw;
	a_ov    = 1'b0;
	a_nan   = 1'b0;
	if (!a_s.v) ;
	else if (a_s.ir[31:27] != 5'b01111) begin
		// multiply/accumulate: aN = F(S) + S(P)
		if (cls == 3'd1) s = a_s.yacc ? unpack40(acc[a_s.y[1:0]]) : unpack40(a_s.y);      // Y (adder side, read now if an accumulator)
		else             s = (mf[2]) ? const_m(mf) : unpack40(acc[mf[1:0]]);            // aM, read now
		aa = from_dfp(s, ff);
		bb = from_prod(m_p, ss);
		nk = 2'd1;
	end
	else begin
		// the special functions (4.6)
		g  = a_s.ir[26:23];
		// Y: the 32-bit word as read, or an accumulator read now (an integer
		// operand in its top bits: ic's byte, float16's half, float32's word)
		if (!a_s.yacc)    yw = a_s.yraw;
		else if (g == 4'd0) yw = {24'd0, acc[a_s.y[1:0]][39:32]};
		else if (g == 4'd2) yw = {16'd0, acc[a_s.y[1:0]][39:24]};
		else if (g == 4'd8) yw = acc[a_s.y[1:0]][39:8];
		else                yw = w32(acc[a_s.y[1:0]]);
		y  = a_s.yacc ? unpack40(acc[a_s.y[1:0]]) : unpack32(a_s.yraw);
		case (g)
			4'd4: begin                                  // round
				nz = fround_pre(y);
				nk = 2'd2;
			end
			4'd5, 4'd6, 4'd7: begin                      // ifalt, ifaeq, ifagt: the last DA result's condition
				c = (g == 4'd5) ? dfl.n : (g == 4'd6) ? dfl.z : (!dfl.n && !dfl.z);
				a_wr   = c;
				a_wval = a_s.yacc ? acc[a_s.y[1:0]] : w40(a_s.yraw);
				a_zd   = c ? (a_s.yacc ? w32(acc[a_s.y[1:0]]) : a_s.yraw) : w32(acc[n]);
				a_zen  = a_s.zw && (c || !a_s.dc[6]);
			end
			4'd14: begin                                 // seed: all bits but the sign inverted
				sw    = yw ^ 32'h7FFFFFFF;
				a_res = unpack32(sw);
				a_fl  = flags_of(a_res);
				a_fl.u = (yw[7:0] == 8'hFF);              // (the exponent inverted to 0: underflow)
				a_fl_en = 1'b1; a_wr = 1'b1; a_wval = pack40(a_res); a_zd = pack32(a_res);
			end
			default: begin                               // the conversions (a3kp_dsp_conv)
				ya = a_s.yacc ? acc[a_s.y[1:0]] : w40(a_s.yraw);
				f2i_args(g, ya, {1'b0, a_s.dc}, a_f2i, a_tx, a_trnd, a_tbits);
				conv(g, yw, ya, {1'b0, a_s.dc}, iv_q, cv, cz, cf, cfe, cnan, cnq, nz);
				a_wr = 1'b1; a_wval = cv; a_zd = cz; a_fl = cf; a_fl_en = cfe; a_nan = cnan;
				a_ov = cfe && (cf.v | cf.u);
				if (cnq) nk = 2'd3;
			end
		endcase
		a_zsz = z_size(a_s.ir);
	end

	// the normalizer's result (the sequence's S1): the multiply-accumulate's
	// sum, round()'s value, an integer converted (ic, float16, float32)
	a_nk = nk;
	a_aa = aa;
	a_bb = bb;
	a_nz = nz;
	nr = nr_q;
	nf = nf_q;
	case (nk)
		2'd1: begin
			a_res   = nr;
			a_fl    = nf;
			a_fl_en = 1'b1;
			a_wr    = 1'b1;
			a_wval  = pack40(nr);
			a_ov    = nf.v | nf.u;
			// Z: the result (classes 1 and 3), the Y operand (the tap forms)
			a_zd    = (cls == 3'd2 || (cls == 3'd1 && mf == 3'd6)) ? a_s.yraw : pack32(nr);
		end
		2'd2: begin
			a_res   = nr;
			a_res.m[7:0] = 8'h00;               // (the guard bits cleared)
			a_fl    = nf;
			a_fl_en = 1'b1;
			a_wr    = 1'b1;
			a_wval  = pack40(a_res);
			a_zd    = pack32(a_res);
			a_ov    = nf.v | nf.u;
		end
		2'd3: begin
			a_res   = nr;
			a_fl    = nf;                       // (an integer: no V, no U)
			a_fl_en = 1'b1;
			a_wval  = pack40(nr);
			a_zd    = pack32(nr);
			a_ov    = 1'b0;
		end
		default: ;
	endcase
end

`include "a3kp_dsp_conv.svh"

// synthesis translate_off
initial begin
	// oc's encoder against the two it replaces, over every 18-bit value
	for (int i = -131072; i < 131072; i++)
		for (int a = 0; a < 2; a++)
			if (oc_enc(33'(i), a[0]) !== (a[0] ? alaw_enc(33'(i)) : mulaw_enc(33'(i)))) begin
				$display("FAIL: dsp: oc %0d law %0d: %02X, reference %02X", i, a, oc_enc(33'(i), a[0]),
				         a[0] ? alaw_enc(33'(i)) : mulaw_enc(33'(i)));
				$finish;
			end
end
// synthesis translate_on

//----------------------------------------------------------------------------
// interrupts: the highest priority one pending and enabled (Table 7-1)
//----------------------------------------------------------------------------
wire [15:0] int_req = {ir1_p, 1'b0 /* OFRM */, 1'b0 /* IFRM */, 1'b0 /* OBE */, 1'b0 /* IBF */, 1'b0,
                       tmr_p, ir0_p, 8'd0} & emr;
reg  [3:0] int_vec;
always @(*) begin
	int_vec = 4'd0;
	for (int i = 15; i >= 8; i--) if (int_req[i]) int_vec = i[3:0];
end
wire int_any = |int_req[15:8];

//----------------------------------------------------------------------------
// an error this cycle (7.5.2), taken at its end: the instruction executing is
// aborted -- its results, the operand stage's pointer updates and load data
//----------------------------------------------------------------------------
logic       take_err, err_nmk, dbl;
logic [3:0] err_ev;
always @(*) begin
	take_err = 1'b0; err_nmk = 1'b0; err_ev = 4'd0;
	if (berr)                          begin take_err = 1'b1; err_nmk = 1'b1; err_ev = 4'd1; end
	else if (dx.ill)                   begin take_err = 1'b1; err_nmk = 1'b1; err_ev = 4'd2; end
	else if (aerr && emr[4])           begin take_err = 1'b1; err_ev = 4'd4; end
	else if (a_s.v && a_ov && emr[5])  begin take_err = 1'b1; err_ev = 4'd5; end
	else if (a_s.v && a_nan && emr[6]) begin take_err = 1'b1; err_ev = 4'd6; end
	dbl = 1'b0;
	if (take_err && level == 2'd2) begin
		if (!err_nmk) take_err = 1'b0;              // a maskable error in the error level: ignored
		else if (err_nm) dbl = 1'b1;                // a second non-maskable error: the double error
	end
end


//----------------------------------------------------------------------------
// the machine
//----------------------------------------------------------------------------
reg [31:0] fetch_q;                 // the fetched word (state 3's view of the state-2 access)
reg        fetch_ok;                // a fetch happened this cycle

// MMIO reads (Figure 3-5, big-endian addresses; a register a word)
function automatic [31:0] mmio_rd(input [9:2] a);
	case (a)
		8'h01: mmio_rd = ibuf;                              // 0x404
		8'h02: mmio_rd = obuf;                              // 0x408
		8'h03: mmio_rd = ioc;                               // 0x40C
		8'h04: mmio_rd = {24'd0, tcon};                     // 0x413
		8'h05: mmio_rd = tcount;                            // 0x414
		8'h06: mmio_rd = {24'd0, bioc};                     // 0x41B
		8'h07: begin                                        // 0x41E: {output register, pin} a bit pair
			logic [15:0] b;
			for (int i = 0; i < 8; i++) b[2*i +: 2] = {bio_q[i], bioc[i] ? bio_q[i] : bio_in[i]};
			mmio_rd = {16'd0, b};
		end
		8'h08: mmio_rd = idp;
		8'h09: mmio_rd = odp;
		8'h0A: mmio_rd = {16'd0, icnt};                     // 0x42A
		8'h0B: mmio_rd = {16'd0, ocnt};                     // 0x42E
		8'h0C: mmio_rd = {24'd0, dmacr};                    // 0x433
		default: mmio_rd = 32'd0;
	endcase
endfunction

// MMIO writes (the lanes written)
task automatic mmio_wr(input [9:2] a, input [3:0] be, input [31:0] d);
	case (a)
		8'h02: begin obuf <= d; obe <= 1'b0; end
		8'h03: ioc <= d;
		8'h04: if (be[0]) tcon <= d[7:0];
		8'h05: begin tinit <= d; tcount <= d; end
		8'h06: if (be[0]) bioc <= d[7:0];
		8'h07: if (be[0] || be[1]) begin
			// bit pairs: 00 keep, 01 clear, 10 set, 11 toggle (Table 10-13)
			for (int i = 0; i < 8; i++)
				case (d[2*i +: 2])
					2'b01: bio_q[i] <= 1'b0;
					2'b10: bio_q[i] <= 1'b1;
					2'b11: bio_q[i] <= ~bio_q[i];
					default: ;
				endcase
		end
		8'h08: idp <= d;
		8'h09: odp <= d;
		8'h0A: icnt <= d[15:0];
		8'h0B: ocnt <= d[15:0];
		8'h0C: if (be[0]) begin
			// dmac: ICS/OCS gate the input / output settings
			dmacr[7:6] <= d[7:6];
			dmacr[3:2] <= d[3:2];
			if (d[4]) dmacr[5:4] <= d[5:4];
			if (d[0]) dmacr[1:0] <= d[1:0];
		end
		default: ;
	endcase
endtask

// a CAU register written: pcsh here, the rest through a3kp_dsp_rf's ports
task automatic reg_write(input [4:0] c, input [31:0] v);
	if (c == R_PCSH) pcsh <= v;
endtask

// an I/O register written (its size's bits)
task automatic io_write(input [4:0] c, input [31:0] v, input [1:0] sz);
	case (c)
		5'd0:  cfl  <= {v[0], v[1], v[2], v[3]};          // ps: the CAU flags only
		5'd8:  emr  <= v[15:0];
		5'd12: if (!pcw[13]) pcw <= v[15:0];               // BRC set: the pcw locked
		5'd14: dauc <= {1'b0, v[6:0]};
		default: ;                                         // ctr (read only), spc
	endcase
endtask

// the end of a state: the DA pointer it used updated (X, Y, Z)
task automatic state_end();
	if (st == 2'd1) y_lo <= pf_p[1:0];
	if (st == 2'd2) z_addr <= pf_p;
endtask

// the end of an instruction cycle: the pipeline advances (fw: the fetched word)
task automatic cycle_end(input [31:0] fw);
	logic        take_int;
	logic [31:0] nfpc;
	logic [2:0]  cls;
	logic [31:0] nd_ir, nd_pc;
	logic        nd_v;
	take_int = 1'b0; cls = 3'd0;

	//------------------------------------------------------------------
	// A: the accumulator, the flags, the Z write's data to W
	//------------------------------------------------------------------
	if (a_s.v && a_wr && !a_s.ni) acc[a_s.ir[22:21]] <= a_wval;
	if (a_s.v && a_fl_en) begin
		dfl <= a_fl;
		ctr <= {ctr[4:0], a_fl.n};
	end
	w_v  <= a_s.v && a_zen;
	w_a  <= a_s.za;
	w_d  <= a_zd;
	w_sz <= a_zsz;

	//------------------------------------------------------------------
	// M -> A, O -> M
	//------------------------------------------------------------------
	a_s <= m_s;
	m_p <= m_prod;
	m_s.v <= 1'b0;
	if (o_da) begin
		logic [39:0] xv, yv, mv;
		logic [31:0] yr;
		logic        ya;
		cls = o_ir[31:29];
		// X: memory, or an accumulator (a multiplier input: read now)
		xv = ox_mem ? w40(xq) : acc[ox[1:0]];
		// Y: memory (a byte, a half or a word), or an accumulator -- read now
		// as a multiplier input (classes 2 and 3), at A as an adder input
		// (class 1) or a special function's operand
		if (oy_mem) begin
			logic [1:0] ysz;
			ysz = y_size(o_ir);
			yr = (ysz == 2'd0) ? {24'd0, yq[31 - 8*y_lo -: 8]} :
			     (ysz == 2'd1) ? {16'd0, y_lo[1] ? yq[15:0] : yq[31:16]} : yq;
			yv = w40(yr);
			ya = 1'b0;
		end
		else begin
			yv = acc[oy[1:0]];
			yr = w32(acc[oy[1:0]]);
			ya = (cls == 3'd1) || o_sf;
			if (ya) yv = {38'd0, oy[1:0]};
		end
		// class 1's multiplier M operand: an accumulator now, or a constant
		mv = (o_ir[28:26] == 3'd5) ? 40'h0000000080 : (o_ir[28] ? 40'd0 : acc[o_ir[27:26]]);
		m_s.v    <= 1'b1;
		m_s.ir   <= o_ir;
		m_s.x    <= xv;
		m_s.y    <= yv;
		m_s.yraw <= yr;
		m_s.yacc <= ya;
		m_s.mop  <= mv;
		m_s.za   <= z_addr;
		m_s.zw   <= oz_mem;
		m_s.ni   <= o_nopint;
		m_s.dc   <= dauc[6:0];
	end

	//------------------------------------------------------------------
	// an error this cycle (take_err, dbl: above)
	//------------------------------------------------------------------
	berr <= 1'b0;
	aerr <= 1'b0;

	//------------------------------------------------------------------
	// the register file, in the order of the states: X, Y, Z pointers,
	// a CA load, the D stage's results
	//------------------------------------------------------------------
	if (!take_err && !dbl) begin
		if (o_k == O_LD) begin
			logic [31:0] v;
			v = ld_ext(o_w, xq, o_addr[1:0]);
			reg_write(o_reg, v);
			cfl <= {v[31], v == 32'd0, 2'b00};
		end
		if (o_k == O_LDIO) io_write(o_reg, ld_ext(o_w, xq, o_addr[1:0]), wsize(o_w));
		if (dx.pm)  reg_write(dx.pm_c, dx.pm_v);
		if (dx.wr)  reg_write(dx.wr_c, dx.wr_v);
		if (dx.fl)  cfl <= dx.fl_v;
		if (dx.lnk) reg_write(dx.lnk_c, d_pc + 32'd8);
		if (dx.io_wr) io_write(dx.io_c, dx.io_v, dx.io_sz);
		if (dx.sftrst) begin level <= 2'd0; err_nm <= 1'b0; end
	end

	//------------------------------------------------------------------
	// D -> O
	//------------------------------------------------------------------
	o_k      <= dx.da ? O_DA : dx.ok;
	o_ir     <= d_ir;
	o_addr   <= dx.oa;
	o_w      <= dx.ow;
	o_reg    <= dx.oreg;
	o_sd     <= dx.osd;
	o_nopint <= 1'b0;
	if (d_v && !d_waiti_hold) dbg_retire <= 1'b1;
`ifdef DSP_TRACE
	if (o_da) $display("[o] %08X x %b y %b yq %08X xq %08X", o_ir, ox_mem, oy_mem, yq, xq);
	if (a_s.v) $display("[dau] %08X wr %b a%0d=%010X fl %b zw %b %08X=%08X", a_s.ir, a_wr, a_s.ir[22:21], a_wval, a_fl, a_zen, a_s.za, a_zd);
	if (d_v && !d_waiti_hold) $display("[dsp] %08X %08X  cfl %b  dx.fl %b %b wr %b r%0d=%08X", d_pc, d_ir, cfl, dx.fl, dx.fl_v, dx.wr, dx.wr_c, dx.wr_v);
`endif

	//------------------------------------------------------------------
	// the next fetch address, DO loops
	//------------------------------------------------------------------
	nfpc = fpc;
	if (fetch_ok) begin
		nfpc = fpc + 32'd4;
		if (dx.lp) begin
			// do: the loop begins with the instruction just fetched
			lp_on    <= 1'b1;
			lp_lock  <= dx.lp_lk;
			lp_start <= fpc;
			lp_end   <= fpc + {23'd0, dx.lp_k, 2'b00};
			lp_cnt   <= dx.lp_l;
			if (dx.lp_k == 7'd0) begin
				if (dx.lp_l != 11'd0) begin nfpc = fpc; lp_cnt <= dx.lp_l - 1'd1; end
				else lp_on <= 1'b0;
			end
		end
		else if (lp_on && fpc == lp_end) begin
			if (lp_cnt != 11'd0) begin nfpc = lp_start; lp_cnt <= lp_cnt - 1'd1; end
			else begin lp_on <= 1'b0; lp_lock <= 1'b0; end
		end
	end
	if (dx.br) nfpc = dx.br_t;

	//------------------------------------------------------------------
	// the next D
	//------------------------------------------------------------------
	nd_v  = 1'b0;
	nd_ir = 32'h80000000;
	nd_pc = fpc;
	if (inj != 2'd0) begin
		nd_v  = 1'b1;
		nd_ir = (inj == 2'd2) ? inj_ir : 32'h80000000;
		nd_pc = inj_pc;
		inj   <= inj - 1'd1;
		if (inj == 2'd1) o_nopint <= 1'b0;
	end
	else if (irsh_v) begin
		nd_v   = 1'b1;
		nd_ir  = irsh;
		nd_pc  = irsh_pc;
		irsh_v <= 1'b0;
	end
	else if (fetch_ok) begin
		nd_v  = 1'b1;
		nd_ir = fw;
		nd_pc = fpc;
	end
	d_v  <= nd_v;
	d_ir <= nd_ir;
	d_pc <= nd_pc;
	d_waiti_hold <= 1'b0;
	if (waiting) d_waiti_hold <= 1'b1;

	// waiti: the instruction after it waits in D for an interrupt
	if (dx.waiti) begin
		waiting      <= 1'b1;
		d_waiti_hold <= 1'b1;
	end
	if (waiting && int_any) begin
		waiting      <= 1'b0;
		d_waiti_hold <= 1'b0;
	end
	if (waiting || d_waiti_hold) begin
		// (D keeps its instruction, nothing is fetched)
		d_v  <= d_v;
		d_ir <= d_ir;
		d_pc <= d_pc;
		if (int_any) d_waiti_hold <= 1'b0;
	end

	// ireturn: the shadows back, the instruction shadow next, the fetch at pcsh
	if (dx.iret) begin
		for (int i = 0; i < 4; i++) acc[i] <= sh_acc[i];
		dauc    <= sh_dauc;
		ctr     <= sh_ctr;
		cfl     <= sh_cfl;
		dfl     <= sh_dfl;
		lp_on   <= sh_lp_on;
		lp_lock <= sh_lp_lock;
		lp_start <= sh_lp_start;
		lp_end  <= sh_lp_end;
		lp_cnt  <= sh_lp_cnt;
		level   <= 2'd0;
		irsh_v  <= irsh_has;
		nfpc    = pcsh;
		d_v     <= 1'b0;
	end
	fpc <= nfpc;

	//------------------------------------------------------------------
	// the interrupt's shadow copy, timed for the base level's DA
	// instructions still in the pipeline (7.5.1)
	//------------------------------------------------------------------
	if (shadow_cnt != 3'd0) begin
		shadow_cnt <= shadow_cnt - 1'd1;
		if (shadow_cnt == 3'd3) begin sh_dauc <= dauc; sh_cfl <= cfl; end
		if (shadow_cnt == 3'd1) begin
			for (int i = 0; i < 4; i++) sh_acc[i] <= acc[i];
			sh_dfl <= dfl;
			sh_ctr <= ctr;
		end
	end

	//------------------------------------------------------------------
	// errors (the abort model) and interrupts (the continuation model)
	//------------------------------------------------------------------
	if (dbl) begin
		level  <= 2'd3;
		halted <= 1'b1;
	end
	else if (take_err) begin
		// abort: the pipeline flushed; call evtp+8N (r20); nop
		d_v     <= 1'b0;
		o_k     <= O_NONE;
		m_s.v   <= 1'b0;
		a_s.v   <= 1'b0;
		w_v     <= 1'b0;
		irsh_v  <= 1'b0;
		inj     <= 2'd2;
		inj_ir  <= {6'b000100, 5'd24, R_EVTP, 9'd0, err_ev, 3'd0};
		inj_pc  <= fpc - 32'd8;                      // (r20: the prefetched instruction's address)
		level   <= 2'd2;
		err_nm  <= err_nmk;
		lp_on   <= 1'b0;
		lp_lock <= 1'b0;
		waiting <= 1'b0;
		d_waiti_hold <= 1'b0;
		tcon[0] <= 1'b0;
		dmacr[0] <= 1'b0;
		dmacr[4] <= 1'b0;
		pcw[13] <= 1'b0;
	end
	else begin
		take_int = int_any && level == 2'd0 && !lp_lock && !dx.noint && inj == 2'd0 && !irsh_v &&
		           !dx.iret && !dx.waiti && !waiting && !d_waiti_hold;
		// (leaving waiti, the instruction after it executes first: 7.4)
		if (take_int) begin
			// the instruction fetched now goes to the shadow, pcsh to the next fetch
			inj      <= 2'd2;
			inj_ir   <= {5'b10000, 6'd1, R_EVTP, 9'd0, int_vec, 3'd0};   // goto evtp+8N
			inj_pc   <= fpc;
			irsh     <= fw;
			irsh_pc  <= fpc;
			irsh_has <= fetch_ok && !dx.br;
			pcsh     <= fetch_ok ? nfpc : fpc;
			if (!fetch_ok || dx.br) pcsh <= nfpc;
			d_v      <= 1'b0;
			level    <= 2'd1;
			sh_lp_on <= lp_on; sh_lp_lock <= lp_lock; sh_lp_start <= lp_start;
			sh_lp_end <= lp_end; sh_lp_cnt <= lp_cnt;
			lp_on    <= 1'b0;
			shadow_cnt <= 3'd4;
			case (int_vec)
				4'd8:  begin ir0_p <= 1'b0; iack_p <= 2'b01; iack_cnt <= 4'd8; end
				4'd9:  tmr_p <= 1'b0;
				4'd15: begin ir1_p <= 1'b0; iack_p <= 2'b10; iack_cnt <= 4'd8; end
				default: ;
			endcase
		end
	end
endtask

// a state's access: X / a CA load (0), Y / a CA store (1), the fetch (2),
// the Z write (3)
logic        bs_go, bs_we;
logic  [1:0] bs_sz;
logic [31:0] bs_ad, bs_wd;
always @(*) begin
	bs_go = 1'b0; bs_we = 1'b0; bs_sz = 2'd2; bs_ad = 32'd0; bs_wd = 32'd0;
	case (st)
		2'd0: if (ox_mem) begin bs_go = 1'b1; bs_ad = pf_p; end
		      else if (o_k == O_LD || o_k == O_LDIO) begin bs_go = 1'b1; bs_ad = o_addr; bs_sz = wsize(o_w); end
		2'd1: if (oy_mem) begin bs_go = 1'b1; bs_ad = pf_p; bs_sz = y_size(o_ir); end
		      else if (o_k == O_ST) begin bs_go = 1'b1; bs_we = 1'b1; bs_ad = o_addr; bs_sz = wsize(o_w); bs_wd = o_sd; end
		2'd2: if (inj == 2'd0 && !irsh_v && !waiting && !d_waiti_hold) begin bs_go = 1'b1; bs_ad = fpc; end
		2'd3: if (w_v) begin bs_go = 1'b1; bs_we = 1'b1; bs_ad = w_a; bs_sz = w_sz; bs_wd = w_d; end
	endcase
end

//----------------------------------------------------------------------------
// the A sequence (see A): S0 (a_q 0), S1 (1), then done (2) until the cycle
// ends -- three clocks, while a cycle has four states (the last one waits
// for it all the same)
//----------------------------------------------------------------------------
// the shared shifter: arithmetic right, or (reversed) logical left, by 0..40
function automatic logic signed [40:0] dsh(input logic signed [40:0] x, input [5:0] n, input left);
	logic [40:0] y, z;
	logic [81:0] w;
	for (int i = 0; i < 41; i++) y[i] = left ? x[40 - i] : x[i];
	w = {{41{left ? 1'b0 : x[40]}}, y} >> n;
	z = w[40:0];
	for (int i = 0; i < 41; i++) dsh[i] = left ? z[40 - i] : z[i];
endfunction

// the highest bit that differs from the sign (0 if none)
function automatic [5:0] lzpos(input logic signed [40:0] v);
	lzpos = 6'd0;
	for (int i = 0; i < 40; i++) if (v[i] != v[40]) lzpos = 6'(i);
endfunction

// the lowest set bit (127 if none)
function automatic [6:0] lsb33(input [32:0] v);
	lsb33 = 7'd127;
	for (int i = 32; i >= 0; i--) if (v[i]) lsb33 = 7'(i);
endfunction

logic  [1:0] a_q = 2'd0;
wire         a_done = (a_q == 2'd2);
wire         st_hold = (st == 2'd3) && !a_done;     // the cycle's last state waits for A
logic signed [40:0] aw_q;            // S0: the sum, the value to normalize, or the integer's shifted mantissa
logic signed [9:0]  ae_q;
logic  [2:0] f_case;                 // the integer: 0 zero, 1 saturated, 2 aw_q, 3 aw_q rounded, 4 below one
logic        f_neg, f_half, f_fr;
logic signed [40:0] mac_sa, mac_sb, f_m, sh_x, sh_y;
logic signed [9:0]  mac_d, f_sh;
logic        mac_big, sh_l;
logic  [6:0] f_k;
logic  [5:0] sh_n, n_pos;
always @(*) begin
	mac_sa  = {a_aa.m[39], a_aa.m};
	mac_sb  = {a_bb.m[39], a_bb.m};
	mac_big = (a_aa.e >= a_bb.e);
	mac_d   = mac_big ? a_aa.e - a_bb.e : a_bb.e - a_aa.e;
	// the float to an integer: value = m x 2^(sh - 31); the shift path
	// (sh -33..30) takes m >>> k, k = 31 - sh
	f_m  = {{8{a_tx.m[32]}}, a_tx.m};
	f_sh = $signed({2'b00, a_tx.e}) - 10'sd128;
	f_k  = 7'(10'sd31 - f_sh);
	n_pos = lzpos(aw_q);
	if (a_q == 2'd0) begin
		// S0: the smaller exponent's operand aligned, or m >>> (k - 1)
		// (its low bit the rounding's first fraction bit)
		sh_l = 1'b0;
		if (a_nk == 2'd1) begin
			sh_x = mac_big ? mac_sb : mac_sa;
			sh_n = (mac_d > 10'sd40) ? 6'd40 : 6'(mac_d);
		end
		else begin
			sh_x = f_m;
			sh_n = (f_k > 7'd41) ? 6'd40 : 6'(f_k - 7'd1);
		end
	end
	else begin
		// S1: normalized, the implicit bit to bit 32
		sh_x = aw_q;
		sh_l = (n_pos <= 6'd32);
		sh_n = sh_l ? 6'd32 - n_pos : n_pos - 6'd32;
	end
	sh_y = dsh(sh_x, sh_n, sh_l);
end

//----------------------------------------------------------------------------
// the register file's writes, in the order of the states: port A the state's
// DA pointer update (X, Y, Z) and, at the cycle's end, a CA load; port B the
// D stage's result (after the load).  r0, pc, -n, +n are not registers,
// pcsh is its own (reg_write).
//----------------------------------------------------------------------------
// the state ends this clock: its on-chip access, or the bus answering (a
// state that starts an external access ends when it answers)
wire st_done  = !reset && ce && !halted && !st_hold &&
                (pend ? m_ack == m_req : !(bs_go && mtype(bs_ad, cmode) == MT_EXT));
wire cyc_done = st_done && st == 2'd3 && !take_err && !dbl;

function automatic logic rf_wok(input [4:0] c);
	rf_wok = c != 5'd0 && c != R_PC && c != R_MN && c != R_PN && c != R_PCSH;
endfunction

logic        wa_en, wb_en;
logic  [4:0] wa_a, wb_a;
logic [31:0] wa_d, wb_d;
always @(*) begin
	wa_en = 1'b0; wa_a = {1'b0, pf[6:3]}; wa_d = pf_new;
	wb_en = 1'b0; wb_a = dx.pm_c; wb_d = dx.pm_v;
	if (reset) begin
		wa_en = 1'b1; wa_a = R_EVTP; wa_d = 32'd0;
	end
	else if (st_done && pf_mem) wa_en = 1'b1;
	else if (cyc_done && o_k == O_LD && rf_wok(o_reg)) begin
		wa_en = 1'b1; wa_a = o_reg; wa_d = ld_ext(o_w, xq, o_addr[1:0]);
	end
	// (one of the three: a call's link, a result, a pointer post-modified)
	if (dx.lnk)     begin wb_a = dx.lnk_c; wb_d = d_pc + 32'd8; end
	else if (dx.wr) begin wb_a = dx.wr_c;  wb_d = dx.wr_v; end
	wb_en = cyc_done && (dx.lnk || dx.wr || dx.pm) && rf_wok(wb_a);
end

a3kp_dsp_rf #(.NR(5)) regs
(
	.clk(clk),
	.wa_en(wa_en),
	.wa_a(wa_a),
	.wa_d(wa_d),
	.wb_en(wb_en),
	.wb_a(wb_a),
	.wb_d(wb_d),
	.ra(rq_a),
	.rd(rq)
);

// the A sequence's registers
wire cyc_adv = st_done && (st == 2'd3);                 // the instruction cycle ends
// synthesis translate_off
// (checked against the combinational reference: a3kp_dsp_pkg's fadd_pre
// and normalize, a3kp_dsp_conv's dfp_to_int)
always @(posedge clk)
	if (cyc_adv && a_s.v) begin
		dfp_t    rr;
		dflags_t rf;
		dsum_t   rs;
		logic signed [32:0] ri;
		rs = (a_nk == 2'd1) ? fadd_pre(a_aa, a_bb) : a_nz;
		rr = normalize(rs.s, rs.e, rf);
		if (a_nk != 2'd0 && (rr !== nr_q || rf !== nf_q)) begin
			$display("FAIL: dsp: A sequence %08X: normalizer %09X/%02X %b, reference %09X/%02X %b",
			         a_s.ir, nr_q.m, nr_q.e, nf_q, rr.m, rr.e, rf);
			$finish;
		end
		ri = dfp_to_int(a_tx, a_trnd, a_tbits);
		if (a_f2i && ri !== iv_q) begin
			$display("FAIL: dsp: A sequence %08X: integer %09X, reference %09X", a_s.ir, iv_q, ri);
			$finish;
		end
	end
// synthesis translate_on
always @(posedge clk) begin
	if (reset || cyc_adv) a_q <= 2'd0;
	else if (!a_done)     a_q <= a_q + 2'd1;

	if (a_q == 2'd0) begin
		// S0: the adder (normalize()'s input: aligned to the larger exponent,
		// the smaller truncated), round()'s or a converted integer's value
		// as they are, or the float-to-integer's shift
		if (a_nk == 2'd1) begin
			if (a_aa.zero)      begin aw_q <= mac_sb; ae_q <= a_bb.e; end
			else if (a_bb.zero) begin aw_q <= mac_sa; ae_q <= a_aa.e; end
			else begin
				aw_q <= sh_y + (mac_big ? mac_sa : mac_sb);
				ae_q <= mac_big ? a_aa.e : a_bb.e;
			end
		end
		else if (a_nk != 2'd0) begin aw_q <= a_nz.s; ae_q <= a_nz.e; end
		else if (f_sh >= 10'sd31) aw_q <= (f_sh == 10'sd32) ? f_m <<< 1 : f_m;
		else aw_q <= sh_y >>> 1;                              // m >>> k: toward -inf
		f_neg  <= a_tx.m[32];
		f_half <= sh_y[0];
		f_fr   <= (lsb33(a_tx.m) < f_k);                      // a fraction bit below k
		if (a_tx.e == 8'd0)                              f_case <= 3'd0;
		else if (f_sh > $signed({4'd0, a_tbits}))        f_case <= 3'd1;
		else if (f_sh >= 10'sd31)                        f_case <= 3'd2;
		else if (f_sh < -10'sd33)                        f_case <= 3'd4;
		else                                             f_case <= 3'd3;
	end

	if (a_q == 2'd1) begin
		logic signed [10:0] en;
		logic signed [41:0] q, maxv, minv;
		// S1: the normalizer -- the result's top two bits differ, then 31
		// fraction bits (the last truncated), the exponent range checked
		nf_q <= '{n: 1'b0, z: 1'b0, v: 1'b0, u: 1'b0};
		en = $signed({ae_q[9], ae_q}) + $signed({5'd0, n_pos}) - 11'sd32;
		if (aw_q == 41'sd0) begin
			nr_q   <= DFP_ZERO;
			nf_q.z <= 1'b1;
		end
		else if (en > 11'sd255) begin
			nf_q.n <= aw_q[40];
			nf_q.v <= 1'b1;
			nr_q.m <= aw_q[40] ? {1'b1, 1'b0, 31'h00000000} : {1'b0, 1'b1, 31'h7FFFFFFF};
			nr_q.e <= 8'd255;
		end
		else if (en < 11'sd1) begin
			nf_q.u <= 1'b1;
			nf_q.z <= 1'b1;
			nr_q   <= DFP_ZERO;
		end
		else begin
			nf_q.n <= aw_q[40];
			nr_q.m <= sh_y[33:1];
			nr_q.e <= en[7:0];
		end
		// the integer: rounded per a_trnd (01 toward -inf, 11 toward 0, else
		// nearest: the first fraction bit), saturated to a_tbits
		case (a_tbits)
			6'd9:    maxv = 42'sd255;
			6'd16:   maxv = 42'sd32767;
			6'd18:   maxv = 42'sd131071;
			default: maxv = 42'sd2147483647;
		endcase
		minv = -maxv - 42'sd1;
		case (f_case)
			3'd0:    q = 42'sd0;
			3'd1:    q = f_neg ? minv : maxv;
			3'd2:    q = {aw_q[40], aw_q};
			3'd4:    q = f_neg ? -42'sd1 : 42'sd0;
			default: case (a_trnd)
				2'b01:   q = {aw_q[40], aw_q};
				2'b11:   q = {aw_q[40], aw_q} + ((f_neg && f_fr) ? 42'sd1 : 42'sd0);
				default: q = {aw_q[40], aw_q} + (f_half ? 42'sd1 : 42'sd0);
			endcase
		endcase
		if (q > maxv) q = maxv;
		if (q < minv) q = minv;
		iv_q <= 33'(q);
	end
end

// the on-chip RAM: its own block (byte-enable M10K inference)
wire [10:0] ram_a  = {bs_ad[12], bs_ad[11:2]};
wire  [3:0] ram_be = be_of(bs_sz, bs_ad[1:0]);
wire [31:0] ram_wd = lanes(bs_sz, bs_wd);
wire        ram_en = !reset && ce && !halted && !st_hold && !pend && bs_go && mtype(bs_ad, cmode) == MT_RAM;
wire        ram_we = ram_en && bs_we;
always @(posedge clk) begin
	if (ram_we) begin
		if (ram_be[0]) ram[ram_a][0] <= ram_wd[7:0];
		if (ram_be[1]) ram[ram_a][1] <= ram_wd[15:8];
		if (ram_be[2]) ram[ram_a][2] <= ram_wd[23:16];
		if (ram_be[3]) ram[ram_a][3] <= ram_wd[31:24];
	end
	if (ram_en) ram_q <= ram[ram_a];
end

always @(posedge clk) begin
	logic        go, we;
	logic [1:0]  sz;
	logic [31:0] ad, wd;
	logic [1:0]  mt;

	dbg_retire <= 1'b0;

	if (ce) begin
		ir0_d <= ir0_n;
		ir1_d <= ir1_n;
		if (ir0_d && !ir0_n) ir0_p <= 1'b1;
		if (ir1_d && !ir1_n) ir1_p <= 1'b1;
		if (iack_cnt != 4'd0) iack_cnt <= iack_cnt - 1'd1;
		else iack_p <= 2'b00;
		// the timer: CKI/2 or CKI/4 (tcon[5]); BIO0 sources are not wired
		tpre <= tpre + 1'd1;
		// (9.3.2: an interrupt when the count reaches zero; at zero a one-shot
		// count stops, a reloading one takes the initial count -- a period of
		// N+1, every tick when N is 0)
		if (tcon[0] && tcon[7:6] == 2'b00 && (tcon[5] ? (tpre == 2'd3) : tpre[0])) begin
			if (tcount == 32'd0) begin
				if (tcon[1]) begin
					tcount <= tinit;
					if (tinit == 32'd0) tmr_p <= 1'b1;
				end
			end
			else begin
				tcount <= tcount - 1'd1;
				if (tcount == 32'd1) tmr_p <= 1'b1;
			end
		end
	end

	if (reset) begin
		st       <= 2'd0;
		pend     <= 1'b0;
		m_req    <= m_ack;
		d_v      <= 1'b0;
		d_waiti_hold <= 1'b0;
		o_k      <= O_NONE;
		m_s.v    <= 1'b0;
		a_s.v    <= 1'b0;
		w_v      <= 1'b0;
		level    <= 2'd0;
		err_nm   <= 1'b0;
		halted   <= 1'b0;
		waiting  <= 1'b0;
		lp_on    <= 1'b0;
		lp_lock  <= 1'b0;
		irsh_v   <= 1'b0;
		ir0_p    <= 1'b0;
		ir1_p    <= 1'b0;
		tmr_p    <= 1'b0;
		dauc     <= 8'd0;
		emr      <= 16'd0;
		// pcw (Table 7-4): 0x038F; bits 10-13 latched from bio[7:4]
		pcw      <= {2'b00, bio_in[4], bio_in[5], bio_in[6], bio_in[7], 10'h38F};
		tcon     <= 8'd0;
		tcount   <= 32'hFFFFFFFF;
		tinit    <= 32'hFFFFFFFF;
		ioc      <= 32'd0;
		dmacr    <= 8'd0;
		bioc     <= 8'd0;
		bio_q    <= 8'd0;
		berr     <= 1'b0;
		aerr     <= 1'b0;
		// the reset sequence: call evtp+0 (r20); nop
		inj      <= 2'd2;
		inj_ir   <= {6'b000100, 5'd24, R_EVTP, 16'd0};
		inj_pc   <= 32'd0;
		fpc      <= 32'd0;
	end
	else if (ce && !halted && !st_hold) begin
		if (pend) begin
			// an external access: done when the bus answers
			if (m_ack == m_req) begin
				pend   <= 1'b0;
				ext_q  <= m_rdata;
				prev_t <= MT_EXT;
				if (m_berr) berr <= 1'b1;
				state_end();
				st <= st + 1'd1;
				if (st == 2'd3) cycle_end(fetch_q);
			end
		end
		else begin
			// this state's access (bs_*)
			go = bs_go; we = bs_we; sz = bs_sz; ad = bs_ad; wd = bs_wd;
			// the previous state's data
			if (st == 2'd1) xq <= prev_q;
			if (st == 2'd2) yq <= prev_q;
			if (st == 2'd3) fetch_q <= prev_q;
			if (st == 2'd2) fetch_ok <= go;
			// alignment
			if (go && ((sz == 2'd2 && ad[1:0] != 2'd0) || (sz == 2'd1 && ad[0]))) aerr <= 1'b1;
			mt = mtype(ad, cmode);
			if (go && mt == MT_EXT) begin
				m_addr  <= ad[31:2];
				m_be    <= be_of(sz, ad[1:0]);
				m_we    <= we;
				m_wdata <= lanes(sz, wd);
				m_req   <= ~m_req;
				pend    <= 1'b1;
			end
			else begin
				if (go) begin
					prev_t <= mt;
					case (mt)
						MT_RAM:  ;                                  // (below)
						MT_ROM:  rom_q  <= dsp_rom(ad[9:2]);
						default: begin
							mmio_q <= mmio_rd(ad[9:2]);
							if (we) mmio_wr(ad[9:2], be_of(sz, ad[1:0]), lanes(sz, wd));
						end
					endcase
				end
				state_end();
				st <= st + 1'd1;
				if (st == 2'd3) cycle_end(prev_q);
			end
		end
	end
end

endmodule
