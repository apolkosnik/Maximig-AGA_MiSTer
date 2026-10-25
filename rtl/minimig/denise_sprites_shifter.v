// this is the sprite parallel to serial converter
// clk is 7.09379 MHz (low resolution pixel clock)
// the sprdata assign circuitry is constructed differently from the hardware
// as described  in the amiga hardware reference manual
// this is to make sure that the horizontal start position of a sprite
// aligns with the bitplane/playfield start position


module denise_sprites_shifter
(
  input   clk,          // 28MHz clock
  input clk7_en,
  input clk7n_en,  // 7MHz clock enable
  input   reset,            // reset
  input  aen,          // address enable
  input  [1:0] address,         // register address input
  input  [8:0] hpos,        // horizontal beam counter
  input aga,
  input [15:0] fmode,
  input shift,
  input [48-1:0] chip48,
  input [15:0] bus_prev,       // the chip bus's previous word (Denise)
  input   dbr,               // a data write is sprite DMA (Agnus dmald), not the copper or CPU
  input   [15:0] data_in,     // bus data in
  output  [1:0] sprdata,      // serialized sprite data out
  output  reg attach        // sprite is attached
);

// register names and adresses
parameter POS  = 2'b00;
parameter CTL  = 2'b01;
parameter DATA = 2'b10;
parameter DATB = 2'b11;

// local signals
reg    [63:0] datla;    // data register A
reg    [63:0] datlb;    // data register B
reg    [63:0] shifta;    // shift register A
reg    [63:0] shiftb;    // shift register B
reg    [8:0] hstart;    // horizontal start value
reg    [1:0] hstart_lo;
reg    armed;        // sprite "armed" signal
reg    load;        // load shift register signal
reg    load_del;

//--------------------------------------------------------------------------------------

reg [15:0] data16;
reg        dma16;
always @(posedge clk) if (clk7_en) begin data16 <= data_in; dma16 <= dbr; end

// switch data according to fmode: sprite DMA brings the wide fetch's other
// words (chip48); a CPU write has only its word (WinUAE, after the AGA
// notes): 32 wide by FMODE bit 2, both halves the written word; by bit 3
// (and 64 wide), the first 16 pixels the previous chip bus word (bus_prev), the rest
// the written word again
reg  [64-1:0] spr_fmode_dat;

always @ (*) begin
  if (dma16)
    case(fmode[3:2])
      2'b00   : spr_fmode_dat = {data16, 48'h000000000000};
      2'b11   : spr_fmode_dat = {data16, chip48[47:0]};
      default : spr_fmode_dat = {data16, chip48[47:32], 32'h00000000};
    endcase
  else
    case(fmode[3:2])
      2'b00   : spr_fmode_dat = {data16, 48'h000000000000};
      2'b01   : spr_fmode_dat = {data16, data16, 32'h00000000};
      2'b10   : spr_fmode_dat = {bus_prev, data16, 32'h00000000};
      default : spr_fmode_dat = {bus_prev, data16, data16, data16};
    endcase
end

// generate armed signal
always @(posedge clk)
  if (clk7_en) begin
    if (reset) // reset disables sprite
      armed <= 0;
    else if (aen && address==CTL) // writing CTL register disables sprite
      armed <= 0;
    else if (aen && address==DATA) // writing data register A arms sprite
      armed <= 1;
  end

//--------------------------------------------------------------------------------------

// generate load signal
always @(posedge clk)
  if (clk7_en) begin
    load <= armed && (hpos[7:0] == hstart[7:0]) && (fmode[15] || (hpos[8] == hstart[8])) ? 1'b1 : 1'b0;
  end

//always @(posedge clk)
//  if (clk7_en) begin
//    load_del <= load;  // AMR - delaying this screws up the scoreboard in hybris.
//  end

//--------------------------------------------------------------------------------------

// POS register
always @(posedge clk)
  if (clk7_en) begin
    if (aen && address==POS)
      hstart[8:1] <= data_in[7:0];
  end

// CTL register
always @(posedge clk)
  if (clk7_en) begin
    if (aen && address==CTL)
      {attach,hstart[0],hstart_lo} <= {data_in[7],data_in[0],aga ? data_in[4:3] : 2'b00};
  end

// data register A
always @(posedge clk) begin
	reg st;
	if(clk7_en && aen && address==DATA) st <= 1;
	if(st & clk7n_en) begin
		st <= 0;
		datla <= spr_fmode_dat;
	end
end

// data register B
always @(posedge clk) begin
	reg st;
	if(clk7_en && aen && address==DATB) st <= 1;
	if(st & clk7n_en) begin
		st <= 0;
		datlb <= spr_fmode_dat;
	end
end

//--------------------------------------------------------------------------------------

// sprite shift register: loaded in step with the pixel clock (the shift
// enable); AGA's fine position (hstart_lo, 1/4 lores pixel) delays the
// output below instead, so the first pixel keeps its width
wire load_s = clk7_en & load;
always @(posedge clk)
  if (load_s) // load new data into shift register
  begin
    shifta[63:0] <= datla[63:0];
    shiftb[63:0] <= datlb[63:0];
  end
  else if (shift)
  begin
    shifta[63:0] <= {shifta[62:0],1'b0};
    shiftb[63:0] <= {shiftb[62:0],1'b0};
  end

// assign serialized output data
// AMR - register the output data to delay it by one clk7, compensating for removing load_del
// Fixed highres sprites by pipelining shifter output.
reg [13:0] sprdata_r;
always @(posedge clk)
  sprdata_r <= {shiftb[63],shifta[63],sprdata_r[13:2]}; // Ugly - are we masking a copper timing problem here?

// 4 clocks behind the shifter (as before), plus the fine position
assign sprdata[1:0] = hstart_lo == 2'd0 ? sprdata_r[7:6] :
                      hstart_lo == 2'd1 ? sprdata_r[5:4] :
                      hstart_lo == 2'd2 ? sprdata_r[3:2] : sprdata_r[1:0];
//--------------------------------------------------------------------------------------

endmodule

