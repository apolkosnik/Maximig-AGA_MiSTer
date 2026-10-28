// The DSP3210's conversion special functions (4.6, 8.2.4): ic, oc, float16,
// int16, float32, int32, ieee, dsp.  conv(g, yw, ya, dauc, ...) gives the
// accumulator's new value, the Z data, the DAU flags (and whether they are
// set) and a NaN error.  yw is Y's 32-bit word (a byte / a half-word in its
// low bits when Y is memory of that size, an accumulator's top byte / half /
// 32 bits for ic / float16 / float32), ya the accumulator-format Y.  An
// integer result sits in the accumulator's top bits (the pages of oc, int16,
// int32, ieee: only the instruction's own Z write formats it in memory).
//
// The companded formats are G.711's (the manual's formulas, 8.2.4.2, are its
// segment values at 1/8 scale): mu-law bytes are stored complemented, A-law
// bytes with the even bits inverted; a float's companded or integer value
// saturates.  dauc: [3] linear output, [2] linear input, [1] A-law output,
// [0] A-law input, [5:4] the rounding (x0 nearest, 01 toward -inf, 11 toward
// 0), [6] the conditional Z write of ifalt/ifaeq/ifagt.

// an integer scaled by 2^-sh (sh 0..1) for the normalizer: exact as a DSP
// float (the 40-bit format holds a 32-bit integer).  normalize() takes 32
// fraction bits: exponent 160 (128 + 32) puts the binary point at bit 0.
function automatic dsum_t int_pre(input logic signed [33:0] v, input [7:0] bias_adj);
	dsum_t r;
	r.s = {{7{v[33]}}, v};
	r.e = 10'sd160 - $signed({2'b00, bias_adj});
	return r;
endfunction

// a float to an integer: rounding per dauc[5:4], saturated to bits
function automatic logic signed [32:0] dfp_to_int(input dfp_t x, input [1:0] rnd, input [5:0] bits);
	logic signed [63:0] m;              // the mantissa, 31 fraction bits
	logic signed [63:0] q, frac_mask;
	int  sh;
	logic signed [63:0] maxv, minv;
	if (x.e == 8'd0) return 33'sd0;
	m  = {{31{x.m[32]}}, x.m};
	sh = int'(x.e) - 128;               // value = m * 2^(sh - 31)
	maxv = (64'sd1 <<< (bits - 6'd1)) - 1;
	minv = -(64'sd1 <<< (bits - 6'd1));
	if (sh > $signed({26'd0, bits})) return (m < 0) ? 33'(minv) : 33'(maxv);
	if (sh >= 31) q = m <<< (sh - 31);
	else if (sh < -33) q = (m < 0) ? -64'sd1 : 64'sd0;
	else begin
		logic signed [63:0] t;
		logic               fr;
		t  = m >>> (31 - sh);           // toward -inf
		frac_mask = (64'sd1 <<< (31 - sh)) - 1;
		fr = (m & frac_mask) != 0;
		case (rnd)
			2'b01:   q = t;                                        // toward -inf
			2'b11:   q = (m < 0 && fr) ? t + 1 : t;                // toward 0
			default: q = (m >>> (30 - sh)) & 64'sd1 ? t + 1 : t;   // nearest: the first fraction bit
		endcase
	end
	if (q > maxv) q = maxv;
	if (q < minv) q = minv;
	return 33'(q);
endfunction

function automatic [7:0] mulaw_enc(input logic signed [32:0] v);   // v: the value x 2 (half units)
	logic [31:0] mag;
	logic [2:0]  n;
	logic [3:0]  m;
	logic        s;
	s   = v[32];
	mag = s ? 32'(-v) : 32'(v);
	// |Y| = (16.5 + M) * 2^N - 16.5  ->  2|Y| + 33 = (33 + 2M) * 2^N
	mag = mag + 32'd33;
	if (mag >= 32'd8031 * 2 + 33) begin n = 3'd7; m = 4'd15; end
	else begin
		n = 3'd0;
		for (int i = 7; i >= 1; i--) if (mag >= (32'd33 << i) && n == 3'd0) n = 3'(i);
		m = 4'(((mag >> n) - 32'd33) >> 1);
	end
	return ~{s, n, m};
endfunction

function automatic [7:0] alaw_enc(input logic signed [32:0] v);
	logic [31:0] mag;
	logic [2:0]  n;
	logic [3:0]  m;
	logic        s;
	s   = !v[32];                       // (A-law: 1 positive)
	mag = v[32] ? 32'(-v) : 32'(v);
	// N >= 1: 2|Y| = (33 + 2M) * 2^N;  N = 0: 2|Y| = 2 + 4M
	if (mag < 32'd66) begin n = 3'd0; m = (mag >= 2) ? 4'((mag - 32'd2) >> 2) : 4'd0; end
	else begin
		n = 3'd1;
		for (int i = 7; i >= 1; i--) if (mag >= (32'd33 << i) && n == 3'd1 && i > 1) n = 3'(i);
		if (mag >= (32'd33 << 7)) n = 3'd7;
		m = (((mag >> n) - 32'd33) >> 1) > 15 ? 4'd15 : 4'(((mag >> n) - 32'd33) >> 1);
	end
	return {s, n, m} ^ 8'h55;
endfunction

task automatic conv(input [3:0] g, input [31:0] yw, input [39:0] ya, input [7:0] dc,
                    output [39:0] av, output [31:0] zd, output dflags_t fl, output fe, output nan,
                    output nq, output dsum_t nv);
	dfp_t r, x, tx;
	logic signed [32:0] iv;
	logic [1:0] trnd;
	logic [5:0] tbits;
	av = 40'd0; zd = 32'd0; fl = '0; fe = 1'b0; nan = 1'b0; nq = 1'b0; nv = '0;
	r = DFP_ZERO;
	// one float-to-integer converter: oc (linear: 9 bits; companded: the
	// value x 2 toward 0, 18 bits), int16, int32
	x     = unpack40(ya);
	tx    = x;
	trnd  = dc[5:4];
	tbits = 6'd32;
	if (g == 4'd1) begin
		if (dc[3]) tbits = 6'd9;                             // (9 bits signed: 0..255 after the clamp)
		else begin
			if (x.e != 8'd0) tx.e = x.e + 1'd1;
			trnd  = 2'b11;
			tbits = 6'd18;
		end
	end
	else if (g == 4'd3) tbits = 6'd16;
	iv = dfp_to_int(tx, trnd, tbits);
	// (ic, float16, float32: their integer to the caller's normalizer, nq)
	case (g)
		4'd0: begin                                          // ic: 8 bits to float
			logic [7:0] b;
			logic signed [33:0] v2;                          // the value x 2
			b = yw[7:0];
			if (dc[2]) v2 = {25'd0, b, 1'b0};                // unsigned linear
			else if (!dc[0]) begin                           // mu-law
				logic [7:0] u;
				u  = ~b;
				v2 = 34'(((32'd33 + {u[3:0], 1'b0}) << u[6:4]) - 32'd33);
				if (u[7]) v2 = -v2;
			end
			else begin                                       // A-law
				logic [7:0] u;
				u  = b ^ 8'h55;
				v2 = (u[6:4] == 3'd0) ? 34'(32'd2 + {u[3:0], 2'b00}) : 34'((32'd33 + {u[3:0], 1'b0}) << u[6:4]);
				if (!u[7]) v2 = -v2;
			end
			nq = 1'b1;
			nv = int_pre(v2, 8'd1);                          // (x 2: one fraction bit)
		end
		4'd1: begin                                          // oc: float to 8 bits
			logic [7:0] b;
			if (dc[3]) b = (iv < 0) ? 8'd0 : (iv > 255) ? 8'hFF : iv[7:0];
			else       b = dc[1] ? alaw_enc(iv) : mulaw_enc(iv);   // (the value x 2)
			av = {b, 32'd0};                             // (the accumulator's top byte)
			zd = {24'd0, b};
		end
		4'd2: begin                                          // float16
			nq = 1'b1;
			nv = int_pre({{18{yw[15]}}, yw[15:0]}, 8'd0);
		end
		4'd3: begin                                          // int16
			av = {iv[15:0], 24'd0};                      // (the upper 16 bits)
			zd = {16'd0, iv[15:0]};
		end
		4'd8: begin                                          // float32
			nq = 1'b1;
			nv = int_pre({{2{yw[31]}}, yw}, 8'd0);
		end
		4'd9: begin                                          // int32
			av = {iv[31:0], 8'd0};                       // (the mantissa and guard bits)
			zd = iv[31:0];
		end
		4'd12: begin                                         // ieee: DSP32 to IEEE
			logic [31:0] w;
			logic [8:0]  e;
			logic [23:0] mag;                                // 1.23 magnitude
			e = 9'd0; mag = 24'd0;
			if (x.e == 8'd0) w = 32'd0;
			else begin
				if (!x.m[32]) begin mag = {1'b1, x.m[30:8]}; e = {1'b0, x.e} - 9'd1; end
				else if (x.m[30:8] == 23'd0) begin mag = 24'h800000; e = {1'b0, x.e}; end   // -2 x 2^(e-128)
				else begin mag = {1'b0, ~x.m[30:8]} + 24'd1; e = {1'b0, x.e} - 9'd1; end
				if (e == 9'd0)       w = 32'd0;
				else if (e >= 9'd255) w = {x.m[32], 31'h7F7FFFFF};
				else                 w = {x.m[32], e[7:0], mag[22:0]};
			end
			av = {w, 8'd0};
			zd = w;
		end
		4'd13: begin                                         // dsp: IEEE to DSP32
			logic [7:0]  e;
			logic [22:0] fr;
			e  = yw[30:23];
			fr = yw[22:0];
			if (e == 8'hFF) begin
				r = yw[31] ? unpack32(32'h800000FF) : unpack32(32'h7FFFFFFF);
				fl = flags_of(r); fl.v = 1'b1;
				nan = (fr != 23'd0);
			end
			else if (e == 8'd0) begin
				r  = DFP_ZERO;
				fl.n = 1'b0; fl.z = 1'b1; fl.v = 1'b0;
				fl.u = (fr != 23'd0);
			end
			else begin
				if (!yw[31]) r = unpack32({1'b0, fr, e + 8'd1});
				else if (fr == 23'd0) r = unpack32({1'b1, 23'd0, e});            // -1.0 x 2^(E-127) = -2 x 2^(e-129)
				else r = unpack32({1'b1, ~fr + 23'd1, e + 8'd1});
				fl = flags_of(r);
			end
			fe = 1'b1;
			av = pack40(r); zd = pack32(r);
		end
		default: ;                                           // (reserved G codes: nothing)
	endcase
endtask
