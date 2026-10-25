//============================================================================
//  a4k_rtc: the A4000's Ricoh RP5C01 battery clock at $DC0000
//
//  Sixteen 4-bit registers (register n at $DC0000 + 4n + 3, A5-A2 select),
//  in four banks chosen by the mode register D (bits 1-0), as WinUAE's
//  get_clock_ricoh/put_clock_ricoh:
//
//    bank 0  the time: 1/10 seconds, 1/10 minutes, 1/10 hours (12-hour
//            mode: bit 1 of register 5 is PM), day of week, 1/10 day,
//            1/10 month, 1/10 year
//    bank 1  the alarm registers; register A bit 0 selects 24-hour mode
//    bank 2  battery RAM, the low nibbles of 13 bytes
//    bank 3  battery RAM, the high nibbles
//    D       mode (bank, alarm enable, timer enable), readable
//    E, F    test and reset, write-only (read 0)
//
//  The time is a BCD clock that counts seconds from the MiSTer's clock
//  (hps_io RTC: BCD seconds, minutes, hours, date, month, year, weekday,
//  bit 64 toggling with each new value) and takes writes to its digits, so
//  Kickstart's SetClock works.  The years are 1978-2077 as AmigaOS counts
//  them: a two-digit year below 78 is 20xx (leap year every fourth).
//============================================================================

module a4k_rtc
(
	input             clk,
	input             reset,
	input             ntsc,         // clk is 28.636 MHz, else 28.375 MHz
	input      [64:0] hps_rtc,

	input             cs,
	input             we,
	input       [3:0] reg_sel,
	input       [3:0] wdata,
	output reg  [3:0] rdata
);

// the time, BCD
reg [7:0] sec, min, mday, mon, year;
reg [3:0] hr_lo, hr_hi;   // registers 4 and 5 as written: 24-hour tens, or 12-hour {PM, tens}
reg [2:0] wday;
reg [3:0] mode_d;
reg [3:0] alarm [13];
reg [7:0] ram   [13];

// one second
reg [24:0] div;
wire [24:0] div_max = ntsc ? 25'd28636359 : 25'd28375159;
wire        tick = (div == div_max);

function automatic [7:0] bcd_inc(input [7:0] v);
	bcd_inc = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
endfunction

// days in the month (BCD month), leap years every fourth (years 1978-2077)
function automatic [7:0] mdays(input [7:0] m, input [7:0] y);
	logic leap;
	leap = ((y[7:4] * 4'd10 + y[3:0]) % 4) == 0;
	case (m)
		8'h02:                      mdays = leap ? 8'h29 : 8'h28;
		8'h04, 8'h06, 8'h09, 8'h11: mdays = 8'h30;
		default:                    mdays = 8'h31;
	endcase
endfunction

wire h24 = alarm[10][0];
wire [1:0] bank = mode_d[1:0];

// the 24-hour BCD hour from the MiSTer as the 12-hour registers {PM, tens}, ones
// (12 AM is 12, 12 PM is 12 with PM)
function automatic [7:0] to12(input [7:0] h24bcd);
	logic [4:0] h;
	h = h24bcd[7:4] * 4'd10 + h24bcd[3:0];
	if (h == 5'd0)       to12 = 8'h12;
	else if (h == 5'd12) to12 = 8'h32;
	else if (h > 5'd12)  to12 = ((h - 5'd12) >= 5'd10) ? {4'd3, 4'(h - 5'd22)} : {4'd2, 4'(h - 5'd12)};
	else                 to12 = h24bcd;
endfunction

// the 12-hour registers {PM, tens}, ones as the 24-hour BCD hour (12 AM is 00)
function automatic [7:0] to24(input [7:0] r12);
	logic [4:0] h;
	h = r12[4] * 4'd10 + r12[3:0];
	if (h == 5'd12)  h = r12[5] ? 5'd12 : 5'd0;
	else if (r12[5]) h = h + 5'd12;
	to24 = (h >= 5'd20) ? {4'd2, 4'(h - 5'd20)} : (h >= 5'd10) ? {4'd1, 4'(h - 5'd10)} : {4'd0, 4'(h)};
endfunction

// the hour after this one, and whether the day ends with it: in 12-hour mode
// 11 -> 12 turns PM over (11 PM -> 12 AM is midnight), 12 -> 01 keeps it
wire [7:0] hr = {hr_hi, hr_lo};
reg  [7:0] hr_next;
reg        hr_wrap;
always @(*) begin
	hr_wrap = 1'b0;
	if (h24) begin
		hr_wrap = (hr[5:0] == 6'h23);
		hr_next = hr_wrap ? 8'h00 : bcd_inc({2'b00, hr[5:0]});
	end
	else if (hr[4:0] == 5'h11) begin
		hr_wrap = hr[5];
		hr_next = {2'b00, ~hr[5], 5'h12};
	end
	else if (hr[4:0] == 5'h12) hr_next = {2'b00, hr[5], 5'h01};
	else                       hr_next = {2'b00, hr[5], 5'(bcd_inc({3'b000, hr[4:0]}))};
end

always @(*) begin
	rdata = 4'h0;
	if (bank >= 2'd2 && reg_sel < 4'hD) rdata = bank[0] ? ram[reg_sel][7:4] : ram[reg_sel][3:0];
	else if (bank == 2'd1 && reg_sel < 4'hD) rdata = alarm[reg_sel];
	else case (reg_sel)
		4'h0: rdata = sec[3:0];
		4'h1: rdata = sec[7:4];
		4'h2: rdata = min[3:0];
		4'h3: rdata = min[7:4];
		4'h4: rdata = hr_lo;
		4'h5: rdata = hr_hi;
		4'h6: rdata = {1'b0, wday};
		4'h7: rdata = mday[3:0];
		4'h8: rdata = mday[7:4];
		4'h9: rdata = mon[3:0];
		4'hA: rdata = mon[7:4];
		4'hB: rdata = year[3:0];
		4'hC: rdata = year[7:4];
		4'hD: rdata = mode_d;
		default: rdata = 4'h0;
	endcase
end

reg old_flag = 1'b0;

always @(posedge clk) begin
	div <= tick ? 25'd0 : div + 1'd1;

	if (reset) begin
		mode_d <= 4'h8;                   // timer enabled, bank 0
	end

	old_flag <= hps_rtc[64];
	if (old_flag ^ hps_rtc[64]) begin
		sec  <= hps_rtc[7:0];
		min  <= hps_rtc[15:8];
		{hr_hi, hr_lo} <= h24 ? hps_rtc[23:16] : to12(hps_rtc[23:16]);
		mday <= hps_rtc[31:24];
		mon  <= hps_rtc[39:32];
		year <= hps_rtc[47:40];
		wday <= hps_rtc[50:48];
		div  <= 25'd0;
	end
	else if (tick && mode_d[3]) begin
		// count the seconds through to the year
		if (sec != 8'h59) sec <= bcd_inc(sec);
		else begin
			sec <= 8'h00;
			if (min != 8'h59) min <= bcd_inc(min);
			else begin
				min <= 8'h00;
				{hr_hi, hr_lo} <= hr_next;
				if (hr_wrap) begin
					wday <= (wday == 3'd6) ? 3'd0 : wday + 1'd1;
					if (mday != mdays(mon, year)) mday <= bcd_inc(mday);
					else begin
						mday <= 8'h01;
						if (mon != 8'h12) mon <= bcd_inc(mon);
						else begin
							mon  <= 8'h01;
							year <= (year == 8'h99) ? 8'h00 : bcd_inc(year);
						end
					end
				end
			end
		end
	end

	if (cs && we) begin
		if (bank >= 2'd2 && reg_sel < 4'hD) begin
			if (bank[0]) ram[reg_sel][7:4] <= wdata;
			else         ram[reg_sel][3:0] <= wdata;
		end
		else if (bank == 2'd1 && reg_sel < 4'hD) begin
			// the alarm registers' unused bits read 0 (WinUAE put_clock_ricoh)
			case (reg_sel)
				4'h0, 4'h1, 4'h9, 4'hC: alarm[reg_sel] <= 4'h0;
				4'h3, 4'h6:             alarm[reg_sel] <= wdata & 4'h7;
				4'h5, 4'h8, 4'hB:       alarm[reg_sel] <= wdata & 4'h3;
				4'hA: begin
					alarm[reg_sel] <= wdata & 4'h1;
					// a change of 12/24-hour mode: the hour as the other mode
					// reads it (WinUAE keeps one time; 1 PM is 13)
					if (wdata[0] != h24) {hr_hi, hr_lo} <= wdata[0] ? to24(hr) : to12(hr);
				end
				default:                alarm[reg_sel] <= wdata;
			endcase
		end
		else case (reg_sel)
			4'h0: sec[3:0]  <= wdata;
			4'h1: sec[7:4]  <= wdata & 4'h7;
			4'h2: min[3:0]  <= wdata;
			4'h3: min[7:4]  <= wdata & 4'h7;
			4'h4: hr_lo     <= wdata;
			4'h5: hr_hi     <= wdata & 4'h3;
			4'h6: wday      <= wdata[2:0];
			4'h7: mday[3:0] <= wdata;
			4'h8: mday[7:4] <= wdata & 4'h3;
			4'h9: mon[3:0]  <= wdata;
			4'hA: mon[7:4]  <= wdata & 4'h1;
			4'hB: year[3:0] <= wdata;
			4'hC: year[7:4] <= wdata;
			4'hD: mode_d    <= wdata;
			default: ;   // E, F: test and reset
		endcase
	end
end

initial begin
	for (int i = 0; i < 13; i++) begin alarm[i] = 4'h0; ram[i] = 8'h00; end
	alarm[10] = 4'h1;                    // 24-hour mode (WinUAE's default)
	{sec, min, hr_hi, hr_lo, mday, mon, year, wday} = {8'h00, 8'h00, 4'h0, 4'h0, 8'h01, 8'h01, 8'h26, 3'd4};
	mode_d = 4'h8;
	div = 25'd0;
end

endmodule
