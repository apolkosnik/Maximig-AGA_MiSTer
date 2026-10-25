`timescale 1ns/1ps
// Ramsey's refresh and page timing in a4k_lbus (with the real SDRAM and DDR3
// controllers), and the PC sampler: built normally it never takes the bus,
// built with MAXIMIG_PCSAMPLE a stalled DDR3 does not hold up a ROM read.
// (After an audit's reproducers, 2026-10-24.)
module tb_ramsey;
reg clk114=0; always #5 clk114=~clk114;
reg [3:0] phase=0; always @(negedge clk114) phase<=phase+1'b1;
wire clk=phase[0], c7=phase[3];
reg reset=1,fast=1,ovl=0;
reg req=0;wire ack;reg[31:2] addr=0;reg[3:0] be=15;reg we=0;reg[31:0] wd=0;reg line=0;reg[1:0] beat=0;wire ce=1;
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
wire dclk,dbusy,dready,dread,dwrite;wire model_busy;reg stallDDR=0;assign dbusy=model_busy|stallDDR;wire[7:0] dbc,dbe;wire[28:0] daddr;wire[63:0] ddout,ddin;
a4k_ddr3 dd(.clk(clk114),.reset(reset),.cpu_req(dq),.cpu_ack(da),.cpu_addr(dad),.cpu_we(dw),.cpu_be(db),.cpu_wdata(dwd),.cpu_rdata(drd),
 .mem2_address(29'd0),.mem2_burstcount(8'd1),.mem2_read(1'b0),.mem2_writedata(64'd0),.mem2_byteenable(8'd0),.mem2_write(1'b0),
 .DDRAM_CLK(dclk),.DDRAM_BUSY(dbusy),.DDRAM_BURSTCNT(dbc),.DDRAM_ADDR(daddr),.DDRAM_DOUT(ddout),.DDRAM_DOUT_READY(dready),.DDRAM_RD(dread),.DDRAM_DIN(ddin),.DDRAM_BE(dbe),.DDRAM_WE(dwrite));
ddr3_model dm(.clk(dclk),.busy(model_busy),.burstcnt(dbc),.addr(daddr),.dout(ddout),.dout_ready(dready),.rd(dread & !stallDDR),.din(ddin),.be(dbe),.we(dwrite & !stallDDR));

int errors=0;
task automatic expect_need(input int got,input int exp,input string what);
 if(got!=exp)begin errors++;$display("FAIL %s: need %0d, expected %0d",what,got,exp);end
endtask
int tick=0;always @(posedge clk)tick<=tick+1;
int need0,took;
task automatic access(input[31:0] a,input bit w,input[3:0] b,input[31:0] v,input bit printit);
 int start,n,phase0,busy0,page0;
 @(negedge clk);addr=a[31:2];we=w;be=b;wd=v;line=0;beat=0;req=~req;
 start=tick;phase0=lb.rf_cnt;busy0=lb.rf_busy;page0=lb.page_open;
 @(negedge clk);need0=lb.need;n=0;
 while(ack!=req)begin @(negedge clk);n++;if(n>2000)$fatal(1,"timeout");end
 if(printit)$display("RAMSEY addr=%h write=%0d phase=%0d busy=%0d page_open=%0d need=%0d elapsed=%0d after_page=%0d",a,w,phase0,busy0,page0,need0,tick-start,lb.page_open);
 took=tick-start;
endtask
initial begin
 fast=0;repeat(8)@(negedge clk);reset=0;repeat(10)@(negedge clk);
 access('h00de0000,1,1,'h29,0);
 wait(lb.ramsey_cfg==8'h29);
 for(int phasewant=232;phasewant<238;phasewant++)begin
  wait(lb.rf_cnt==20 && lb.rf_busy==0);access('h07010000,1,15,'h12345678,0);
  wait(lb.rf_cnt==phasewant && lb.rf_busy==0);access('h07010004,1,15,'habcdef01,1);
  // the beat on the clock the refresh starts (237: the interval is 238) sees
  // it: the page closed (7) and four clocks of refresh, as a clock later
  expect_need(need0,phasewant==237?11:3,$sformatf("page hit at refresh phase %0d",phasewant));
 end
 for(int busywant=4;busywant>0;busywant--)begin
  wait(lb.rf_cnt==20 && lb.rf_busy==0);access('h07010000,1,15,'h12345678,0);
  wait(lb.rf_busy==busywant);access('h07010004,1,15,'habcdef01,1);
  expect_need(need0,7+busywant,$sformatf("during the refresh, %0d to run",busywant));
 end
 // Changing a page within a refresh must also charge the miss penalty.
 wait(lb.rf_cnt==20 && lb.rf_busy==0);access('h07010000,1,15,'h12345678,0);
 wait(lb.rf_cnt==237 && lb.rf_busy==0);access('h07010800,1,15,'habcdef01,1);
 expect_need(need0,11,"another page on the refresh's first clock");
 // the PC sampler
 fast=1;
`ifdef MAXIMIG_PCSAMPLE
 stallDDR=1;
 wait(lb.st==12 && dq!=da);
 fork
  begin repeat(600)@(posedge clk);stallDDR=0;end
  begin access('h00f80000,0,15,0,0);if(took>30)begin errors++;$display("FAIL a ROM read behind a stalled sampler write took %0d clocks",took);end end
 join
`else
 repeat(3*4096)@(posedge clk) if(lb.st==11 || lb.st==12)begin errors++;$display("FAIL the PC sampler ran in a normal build");break;end
`endif
 if(errors)$fatal(1,"errors=%0d",errors);
 $display("PASS: Ramsey refresh and page timing, the PC sampler");
 $finish;
end
endmodule
