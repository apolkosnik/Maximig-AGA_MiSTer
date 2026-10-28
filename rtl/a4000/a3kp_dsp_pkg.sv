//============================================================================
//  a3kp_dsp_pkg: the DSP3210's floating-point arithmetic (WE DSP3210
//  Information Manual, AT&T 1991: 3.3.3, 8.2)
//
//  The DSP32 format: a 24-bit normalized 2's complement mantissa (sign and
//  23 fraction bits; the implicit bit is the sign's complement) and an
//  exponent biased by 128: N = M * 2^(e-128), 1 <= M < 2 or -2 <= M < -1;
//  e = 0 is zero (a dirty zero -- sign or fraction set -- is zero too).
//  The accumulators are the 40-bit format: 8 more fraction (guard) bits.
//
//  Here a value is {m, e}: m the 33-bit 2's complement mantissa {s, the
//  implicit bit, 23 fraction bits, 8 guard bits} (units of 2^-31), e the
//  biased exponent.
//
//  Precision (Figure 8-9): the multiplier takes 24-bit mantissas (an
//  accumulator's guard bits are truncated), its product keeps 32 fraction
//  bits (the 14 LSBs truncated) and three integer bits; the adder adds the
//  product to a 40-bit operand and normalizes; the result is truncated to
//  the accumulator's 31 fraction bits.  A result whose exponent leaves
//  1..255 overflows (V: saturated to the largest magnitude of its sign, as
//  the IEEE conversion's infinities, 0x7fffffff / 0x800000ff) or underflows
//  (U: zero) -- the manual gives the ranges (7.5.3.4) and the flags, not
//  the stored value; the saturation follows the DSP32C family as MAME's
//  core models it.
//============================================================================

package a3kp_dsp_pkg;

typedef struct packed {
	logic [32:0] m;
	logic  [7:0] e;
} dfp_t;

typedef struct packed {
	logic n, z, v, u;
} dflags_t;

localparam dfp_t DFP_ZERO = '{m: 33'd0, e: 8'd0};

// a 32-bit memory word / a 40-bit accumulator as a value
function automatic dfp_t unpack32(input [31:0] w);
	dfp_t r;
	if (w[7:0] == 8'd0) r = DFP_ZERO;
	else begin
		r.m = {w[31], ~w[31], w[30:8], 8'h00};
		r.e = w[7:0];
	end
	return r;
endfunction

function automatic dfp_t unpack40(input [39:0] a);
	dfp_t r;
	if (a[7:0] == 8'd0) r = DFP_ZERO;
	else begin
		r.m = {a[39], ~a[39], a[38:8]};
		r.e = a[7:0];
	end
	return r;
endfunction

function automatic [39:0] pack40(input dfp_t x);
	if (x.e == 8'd0) return 40'd0;
	return {x.m[32], x.m[30:0], x.e};
endfunction

// to memory: the guard bits truncated (a 40-bit bus onto 32 bits)
function automatic [31:0] pack32(input dfp_t x);
	if (x.e == 8'd0) return 32'd0;
	return {x.m[32], x.m[30:8], x.e};
endfunction

// a 32-bit word in the 40-bit format (zero guard bits) and back (the
// guard bits dropped): {mantissa 24, guard 8, exponent 8}
function automatic [39:0] w40(input [31:0] w);
	return {w[31:8], 8'h00, w[7:0]};
endfunction

function automatic [31:0] w32(input [39:0] a);
	return {a[39:16], a[7:0]};
endfunction

// a multiplier input: the guard bits truncated
function automatic dfp_t trunc24(input dfp_t x);
	dfp_t r;
	r = x;
	r.m[7:0] = 8'h00;
	return r;
endfunction

// the product: 36-bit mantissa (4 integer bits, 32 fraction bits) and an
// unbiased-range exponent (10 bits, signed); zero flagged
typedef struct packed {
	logic [35:0] m;
	logic signed [9:0] e;
	logic        zero;
} dprod_t;

function automatic dprod_t fmul(input dfp_t x, input dfp_t y);
	dprod_t p;
	logic signed [24:0] mx, my;
	logic signed [49:0] pr;
	mx = $signed(x.m[32:8]);
	my = $signed(y.m[32:8]);
	pr = mx * my;                       // 46 fraction bits
	p.m    = 36'(pr >>> 14);            // 32 fraction bits, the 14 LSBs truncated
	p.e    = $signed({2'b00, x.e}) + $signed({2'b00, y.e}) - 10'sd128;
	p.zero = (x.e == 8'd0) || (y.e == 8'd0) || (pr == 50'd0);
	return p;
endfunction

// a value as the adder sees it: 40-bit 2's complement mantissa, 32 fraction
// bits, the exponent as a signed 10-bit
typedef struct packed {
	logic signed [39:0] m;
	logic signed [9:0]  e;
	logic               zero;
} dadd_t;

function automatic dadd_t from_dfp(input dfp_t x, input neg);
	dadd_t a;
	logic signed [39:0] m;
	m = {{6{x.m[32]}}, x.m, 1'b0};
	a.m    = neg ? -m : m;
	a.e    = $signed({2'b00, x.e});
	a.zero = (x.e == 8'd0);
	return a;
endfunction

function automatic dadd_t from_prod(input dprod_t p, input neg);
	dadd_t a;
	logic signed [39:0] m;
	m = {{4{p.m[35]}}, p.m};
	a.m    = neg ? -m : m;
	a.e    = p.e;
	a.zero = p.zero;
	return a;
endfunction

// normalize a 2's complement mantissa (32 fraction bits) at exponent e:
// the result's top two bits differ ({0,1}: [1,2), {1,0}: [-2,-1)); then
// truncated to 31 fraction bits; the exponent range checked
function automatic dfp_t normalize(input logic signed [40:0] s, input logic signed [9:0] e,
                                   output dflags_t fl);
	dfp_t r;
	int   pos;
	logic signed [10:0] en;
	logic signed [40:0] t;
	fl = '{n: 1'b0, z: 1'b0, v: 1'b0, u: 1'b0};
	if (s == 41'sd0) begin
		fl.z = 1'b1;
		return DFP_ZERO;
	end
	// the highest bit that differs from the sign
	pos = 0;
	for (int i = 0; i < 40; i++)
		if (s[i] != s[40]) pos = i;
	// the implicit bit belongs at bit 32
	if (pos > 32) t = s >>> (pos - 32);
	else          t = s <<< (32 - pos);
	en = $signed({e[9], e}) + 11'(pos - 32);
	fl.n = s[40];
	if (en > 11'sd255) begin
		fl.v = 1'b1;
		r.m  = s[40] ? {1'b1, 1'b0, 31'h00000000} : {1'b0, 1'b1, 31'h7FFFFFFF};
		r.e  = 8'd255;
	end
	else if (en < 11'sd1) begin
		fl.u = 1'b1;
		fl.z = 1'b1;
		fl.n = 1'b0;
		r    = DFP_ZERO;
	end
	else begin
		r.m = t[33:1];                  // 31 fraction bits: the last one truncated
		r.e = en[7:0];
	end
	return r;
endfunction

// a value for the normalizer: a 2's complement mantissa with 32 fraction
// bits and a signed exponent (zero: a zero result)
typedef struct packed {
	logic signed [40:0] s;
	logic signed [9:0]  e;
} dsum_t;

// a + b (each possibly negated by its caller) before normalizing: aligned
// to the larger exponent, the smaller shifted right with truncation
function automatic dsum_t fadd_pre(input dadd_t a, input dadd_t b);
	logic signed [40:0] sa, sb;
	dsum_t r;
	int d;
	sa  = {a.m[39], a.m};
	sb  = {b.m[39], b.m};
	r.e = a.e;
	if (a.zero) begin sa = 41'sd0; r.e = b.e; end
	else if (b.zero) sb = 41'sd0;
	else if (a.e >= b.e) begin
		d  = a.e - b.e;
		sb = (d > 40) ? (sb >>> 40) : (sb >>> d);
	end
	else begin
		d   = b.e - a.e;
		sa  = (d > 40) ? (sa >>> 40) : (sa >>> d);
		r.e = b.e;
	end
	r.s = sa + sb;
	return r;
endfunction

// round(): 40 bits to 32, to nearest, a tie to the greater value -- half a
// 32-bit LSB (2^-24, 2^8 in 32 fraction-bit units) added, the bits below
// it cleared; normalized after (the guard bits then cleared too)
function automatic dsum_t fround_pre(input dfp_t x);
	dsum_t r;
	r.e = $signed({2'b00, x.e});
	if (x.e == 8'd0) r.s = 41'sd0;
	else begin
		r.s = {{7{x.m[32]}}, x.m, 1'b0} + 41'sd256;
		r.s[8:0] = 9'd0;
	end
	return r;
endfunction

// the flags of a value written without arithmetic (a load, a conversion)
function automatic dflags_t flags_of(input dfp_t x);
	dflags_t f;
	f.n = (x.e != 8'd0) && x.m[32];
	f.z = (x.e == 8'd0);
	f.v = 1'b0;
	f.u = 1'b0;
	return f;
endfunction

endpackage
