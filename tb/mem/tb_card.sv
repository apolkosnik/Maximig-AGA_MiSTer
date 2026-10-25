`timescale 1ns/1ps
module tb_card;
reg clk114=0; always #5 clk114=~clk114;
reg [3:0] phase=0; always @(negedge clk114) phase<=phase+1'b1;
wire clk=phase[0], c7=phase[3];
reg reset=1,fast=1,ovl=0;
wire req,ack;wire [31:2] addr;wire [3:0] be;wire we;wire[31:0] wd;wire line;wire[1:0] beat;
reg [2:0] speed=4;wire ce,clk_cpu;
a4k_cpuclk clocks(.clk_57(clk),.speed(speed),.cpu_ce(ce),.clk_cpu(clk_cpu));
reg [31:0] ca=0,cwd=0;reg ts=1,rw=1;reg [1:0] sz=0;wire[31:0] crd;wire ta,tea,tci;
a4k_a3640 card(.clk(clk),.ce(ce),.reset(reset),.a(ca),.ts_n(ts),.rw_n(rw),.siz(sz),.tt(2'd0),.tm(3'd5),.d_cpu(cwd),.d_mem(crd),.ta_n(ta),.tea_n(tea),.tci_n(tci),.pre(3'd0),.post(3'd0),
 .lb_req(req),.lb_ack(ack),.lb_addr(addr),.lb_be(be),.lb_we(we),.lb_wdata(wd),.lb_line(line),.lb_beat(beat),.lb_rdata(rd),.lb_berr(berr),.lb_ci(ci));
wire[31:0] rd; wire berr,ci;
wire sq,sa,sw; wire[24:2] sad; wire[3:0] sb; wire[31:0] swd;wire[63:0] srd;
wire dq,da,dw;wire[28:2] dad;wire[3:0] db;wire[31:0] dwd;wire[127:0] drd;
a4k_lbus lb(.clk(clk),.ce(ce),.reset(reset),.io_reset(reset),.pwrup(reset),.fast(fast),.mbram(2'd3),
 .z3ram256_fit(1'b1),.z3ram128_fit(1'b1),.rtg_fit(1'b1),.a2065_fit(1'b0),.toccata_fit(1'b0),.rom_speed(2'd0),.ovl(ovl),.extrom_on(1'b1),.iack7_t(1'b0),.cart_ar(1'b0),.freeze_t(1'b0),.nmi_t(),.dbg_pc(32'h1234),
 .lb_req(req),.lb_ack(ack),.lb_addr(addr),.lb_be(be),.lb_we(we),.lb_wdata(wd),.lb_line(line),.lb_beat(beat),.lb_tt(2'd0),.lb_tm(3'd5),.lb_rdata(rd),.lb_berr(berr),.lb_ci(ci),
 .sd_req(sq),.sd_ack(sa),.sd_addr(sad),.sd_we(sw),.sd_be(sb),.sd_wdata(swd),.sd_rdata(srd),
 .dd_req(dq),.dd_ack(da),.dd_addr(dad),.dd_we(dw),.dd_be(db),.dd_wdata(dwd),.dd_rdata(drd),.sb_ack(1'b0),.sb_rdata(32'd0),.rtg_pal_dr(24'd0));
wire [12:0] s_a; wire [1:0] s_ba,s_dqm; tri[15:0] s_data;wire s_clk,s_we,s_ras,s_cas,s_cs,s_cke;
reg chipDMA=1,chipRW=1,chip32=0; reg[24:1] chipAddr=0;reg[15:0] chipWR=0,chipWR2=0;wire[15:0] chipRD,chipRD2;wire[47:0] chip48;
a4k_sdram sd(.sysclk(clk114),.c_7m(c7),.reset_n(!reset),.sd_addr(s_a),.sd_ba(s_ba),.sd_cs(s_cs),.sd_we(s_we),.sd_ras(s_ras),.sd_cas(s_cas),.sd_dqm(s_dqm),.sd_data(s_data),.sd_clk(s_clk),.sd_cke(s_cke),
 .chipAddr(chipAddr),.chipL(1'b0),.chipU(1'b0),.chipRW(chipRW),.chipDMA(chipDMA),.chipWR(chipWR),.chipRD(chipRD),.chip48(chip48),.chip32(chip32),.chipWR2(chipWR2),.chipRD2(chipRD2),
 .cpu_req(sq),.cpu_ack(sa),.cpu_addr(sad),.cpu_we(sw),.cpu_be(sb),.cpu_wdata(swd),.cpu_rdata(srd));
sdram_model sm(.clk(s_clk),.a(s_a),.ba(s_ba),.dq(s_data),.dqml(s_dqm[0]),.dqmh(s_dqm[1]),.cs_n(s_cs),.ras_n(s_ras),.cas_n(s_cas),.we_n(s_we));
wire dclk,dbusy,dready,dread,dwrite;wire[7:0] dbc,dbe;wire[28:0] daddr;wire[63:0] ddout,ddin;
a4k_ddr3 dd(.clk(clk114),.reset(reset),.cpu_req(dq),.cpu_ack(da),.cpu_addr(dad),.cpu_we(dw),.cpu_be(db),.cpu_wdata(dwd),.cpu_rdata(drd),
 .mem2_address(29'd0),.mem2_burstcount(8'd1),.mem2_read(1'b0),.mem2_writedata(64'd0),.mem2_byteenable(8'd0),.mem2_write(1'b0),
 .DDRAM_CLK(dclk),.DDRAM_BUSY(dbusy),.DDRAM_BURSTCNT(dbc),.DDRAM_ADDR(daddr),.DDRAM_DOUT(ddout),.DDRAM_DOUT_READY(dready),.DDRAM_RD(dread),.DDRAM_DIN(ddin),.DDRAM_BE(dbe),.DDRAM_WE(dwrite));
ddr3_model dm(.clk(dclk),.busy(dbusy),.burstcnt(dbc),.addr(daddr),.dout(ddout),.dout_ready(dready),.rd(dread),.din(ddin),.be(dbe),.we(dwrite));
int errors=0,checks=0; int refreshes=0,slots=0,cpuslots=0;
// refreshes, and the longest run of SDRAM slots without one (8192 in 64 ms
// is one in 55 slots of 141 ns; a4k_sdram guarantees one in 32)
int since=0,maxgap=0;
always @(posedge s_clk) if(!s_cs && {s_ras,s_cas,s_we}==3'b001) begin refreshes++;since=0;end
always @(posedge sd.sysclk) if(sd.init_done && sd.sdram_state==0) begin since++;if(since>maxgap)maxgap=since;end
always @(posedge clk114) if(sd.init_done && sd.sdram_state==0) begin slots++;if(sq!=sa) cpuslots++;end


reg [127:0] got; int xfers=0;int gap=1;initial if(!$value$plusargs("gap=%d",gap))gap=1;
task automatic transfer(input[31:0] a,input bit w,input[1:0] size,input[127:0] data);
 int n,count;
 repeat(gap)@(posedge clk_cpu);
 @(negedge clk_cpu);ca=a;rw=!w;sz=size;cwd=size==3?data[127-a[3:2]*32-:32]:data[31:0];ts=0;
 @(negedge clk_cpu);ts=1;count=size==3?4:1;
 for(int b=0;b<count;b++)begin
  n=0;do begin @(posedge clk_cpu);n++;if(n>2000)$fatal(1,"card timeout");end while(ta && tea);
  if(!tea)$fatal(1,"card bus error");
  got[127-((a[3:2]+b)%4)*32-:32]=crd;
  if(size==3)cwd<=data[127-((a[3:2]+b+1)%4)*32-:32];
 end
 xfers++;
endtask
int r0,s0,c0;reg[127:0] v;reg[31:0] laneexp,laneval;
reg dma_pressure=0;
// A continuous half-rate DMA master: one chip slot in every pair.
int slotphase=0;
always @(negedge clk114) if(sd.sdram_state==15)begin slotphase++;chipDMA=!(dma_pressure && slotphase[0]);end
initial begin
 repeat(8)@(negedge clk);reset=0;repeat(300)@(negedge clk);
 for(int f=0;f<2;f++)for(int sp=0;sp<5;sp++)begin
  fast=f;speed=3'(sp);repeat(30)@(negedge clk);
  for(int start=0;start<4;start++)begin
   v=128'h0123456789abcdeffedcba9876543210 ^ (128'(start)<<32);
   transfer('h07000000+4*start,1,3,v);
   transfer('h07000000+4*start,0,3,0);
   checks++;if(got!==v)begin errors++;$display("FAIL card burst f=%d speed=%d start=%d got=%h exp=%h",f,sp,start,got,v);end
  end
  for(int lane=0;lane<4;lane++)begin
   transfer('h07000200,1,0,128'h12345678);
   laneval=32'hab000000>>(8*lane);laneexp=(32'h12345678 & ~(32'hff000000>>(8*lane)))|laneval;
   transfer('h07000200+lane,1,1,128'(laneval));
   transfer('h07000200,0,0,0);
   checks++;if(got[127:96]!==laneexp)begin errors++;$display("FAIL CARD byte f=%d speed=%d lane=%d got=%h exp=%h",f,sp,lane,got[127:96],laneexp);end
  end
  for(int lane=0;lane<4;lane+=2)begin
   transfer('h07000200,1,0,128'h12345678);
   laneval=32'habcd0000>>(8*lane);laneexp=(32'h12345678 & ~(32'hffff0000>>(8*lane)))|laneval;
   transfer('h07000200+lane,1,2,128'(laneval));
   transfer('h07000200,0,0,0);
   checks++;if(got[127:96]!==laneexp)begin errors++;$display("FAIL CARD word f=%d speed=%d lane=%d got=%h exp=%h",f,sp,lane,got[127:96],laneexp);end
  end
 end
 $display("CARD bursts checks=%0d errors=%0d",checks,errors);
 if($test$plusargs("long"))begin
 fast=1;speed=4;dma_pressure=0;repeat(30)@(negedge clk);r0=refreshes;s0=slots;
 for(int i=0;i<150000;i++)transfer('h07010000+16*(i%64),1,3,128'(i));
 $display("LONG STREAM lines=150000 longword_writes=600000 refreshes=%0d slots=%0d",refreshes-r0,slots-s0);$finish;
 end
 for(int dp=0;dp<2;dp++)for(int f=0;f<2;f++)begin
  fast=f;speed=4;dma_pressure=dp;repeat(30)@(negedge clk);
  r0=refreshes;s0=slots;c0=cpuslots;maxgap=0;since=0;
  for(int i=0;i<2000;i++)transfer('h07010000+16*(i%64),1,3,128'(i));
  $display("CARD STREAM lines=2000 dma=%0d fast=%0d refreshes=%0d slots=%0d pending_slots=%0d maxgap=%0d",dp,f,refreshes-r0,slots-s0,cpuslots-c0,maxgap);
  checks++;if(maxgap>32)begin errors++;$display("FAIL refresh starved: %0d slots without one (at most 32)",maxgap);end
 end
 $display("CARD DONE checks=%0d errors=%0d",checks,errors);
 if(errors)$fatal(1,"errors=%0d",errors);
 $finish;
end
initial begin #200000000;$fatal(1,"global timeout");end
endmodule
