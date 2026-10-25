`timescale 1ns/1ps
module tb_memory;
reg clk114=0; always #5 clk114=~clk114;
reg [3:0] phase=0; always @(negedge clk114) phase<=phase+1'b1;
wire clk=phase[0], c7=phase[3];
reg reset=1,fast=1,ovl=0;
reg req=0; wire ack; reg [31:2] addr=0; reg [3:0] be=15; reg we=0; reg[31:0] wd=0; reg line=0; reg [1:0] beat=0;
wire[31:0] rd; wire berr,ci;
wire sq,sa,sw; wire[24:2] sad; wire[3:0] sb; wire[31:0] swd;wire[63:0] srd;
wire dq,da,dw;wire[28:2] dad;wire[3:0] db;wire[31:0] dwd;wire[127:0] drd;
wire pclk,pwr;wire[7:0] pa;wire[23:0] pd;reg[23:0] pq=0;reg[23:0] palette[256];
always @(posedge pclk)begin pq<=palette[pa];if(pwr)palette[pa]<=pd;end
a4k_lbus lb(.clk(clk),.ce(1'b1),.reset(reset),.io_reset(reset),.pwrup(reset),.fast(fast),.mbram(2'd3),
 .z3ram256_fit(1'b1),.z3ram128_fit(1'b1),.rtg_fit(1'b1),.a2065_fit(1'b0),.toccata_fit(1'b0),.rom_speed(2'd0),.ovl(ovl),.extrom_on(1'b1),.iack7_t(1'b0),.cart_ar(1'b0),.freeze_t(1'b0),.nmi_t(),.dbg_pc(32'h1234),
 .lb_req(req),.lb_ack(ack),.lb_addr(addr),.lb_be(be),.lb_we(we),.lb_wdata(wd),.lb_line(line),.lb_beat(beat),.lb_tt(2'd0),.lb_tm(3'd5),.lb_rdata(rd),.lb_berr(berr),.lb_ci(ci),
 .sd_req(sq),.sd_ack(sa),.sd_addr(sad),.sd_we(sw),.sd_be(sb),.sd_wdata(swd),.sd_rdata(srd),
 .dd_req(dq),.dd_ack(da),.dd_addr(dad),.dd_we(dw),.dd_be(db),.dd_wdata(dwd),.dd_rdata(drd),.sb_ack(1'b0),.sb_rdata(32'd0),.rtg_pal_dr(pq),.rtg_pal_clk(pclk),.rtg_pal_wr(pwr),.rtg_pal_a(pa),.rtg_pal_dw(pd));
wire [12:0] s_a; wire [1:0] s_ba,s_dqm; tri[15:0] s_data;wire s_clk,s_we,s_ras,s_cas,s_cs,s_cke;
reg chipDMA=1,chipRW=1,chip32=0,chipU=0,chipL=0; reg[24:1] chipAddr=0;reg[15:0] chipWR=0,chipWR2=0;wire[15:0] chipRD,chipRD2;wire[47:0] chip48;
a4k_sdram sd(.sysclk(clk114),.c_7m(c7),.reset_n(!reset),.sd_addr(s_a),.sd_ba(s_ba),.sd_cs(s_cs),.sd_we(s_we),.sd_ras(s_ras),.sd_cas(s_cas),.sd_dqm(s_dqm),.sd_data(s_data),.sd_clk(s_clk),.sd_cke(s_cke),
 .chipAddr(chipAddr),.chipL(chipL),.chipU(chipU),.chipRW(chipRW),.chipDMA(chipDMA),.chipWR(chipWR),.chipRD(chipRD),.chip48(chip48),.chip32(chip32),.chipWR2(chipWR2),.chipRD2(chipRD2),
 .cpu_req(sq),.cpu_ack(sa),.cpu_addr(sad),.cpu_we(sw),.cpu_be(sb),.cpu_wdata(swd),.cpu_rdata(srd));
sdram_model sm(.clk(s_clk),.a(s_a),.ba(s_ba),.dq(s_data),.dqml(s_dqm[0]),.dqmh(s_dqm[1]),.cs_n(s_cs),.ras_n(s_ras),.cas_n(s_cas),.we_n(s_we));
wire dclk,dbusy,dready,dread,dwrite;wire model_busy;reg[15:0] rng=16'hb00b;always @(posedge clk114)rng<={rng[14:0],rng[15]^rng[13]^rng[12]^rng[10]};wire stall=rng[2:0]<3'd4;assign dbusy=model_busy|stall;wire[7:0] dbc,dbe;wire[28:0] daddr;wire[63:0] ddout,ddin;
reg[28:0] m2addr=0;reg[7:0] m2count=1;reg m2rd=0,m2wr=0;reg[63:0] m2wd=0;wire[63:0] m2data;wire m2valid,m2wait;
int m2got=0,m2checks=0,m2errors=0;reg m2active=0,m2done=0;reg[28:0] m2base=0;
function automatic[63:0] pattern(input[28:0] a);pattern=64'h1020304050607080^(64'(a)*64'h010305070b0d1113);endfunction
always @(posedge clk114)if(m2valid)begin
 m2checks++;if(!m2active || m2data!==pattern(m2base+m2got))begin m2errors++;$display("FAIL MEM2 active=%b idx=%0d got=%h expected=%h",m2active,m2got,m2data,pattern(m2base+m2got));end
 m2got++;
end
initial begin
 wait(!reset);repeat(300)@(negedge clk114);
 for(int run=0;run<100;run++)begin
  @(negedge clk114);m2base=29'h04ff0000+run*64;m2addr=m2base;m2count=8'(1+run%32);m2wr=1;
  for(int b=0;b<int'(m2count);b++)begin
   m2wd=pattern(m2base+b);
   do @(posedge clk114);while(m2wait);
   @(negedge clk114);
  end
  m2wr=0;
  repeat(2)@(negedge clk114);m2rd=1;m2got=0;m2active=1;
  do @(posedge clk114);while(m2wait);
  @(negedge clk114);m2rd=0;
  wait(m2got==int'(m2count));@(negedge clk114);m2active=0;
 end
 m2done=1;$display("MEM2 checks=%0d errors=%0d",m2checks,m2errors);
end
a4k_ddr3 dd(.clk(clk114),.reset(reset),.cpu_req(dq),.cpu_ack(da),.cpu_addr(dad),.cpu_we(dw),.cpu_be(db),.cpu_wdata(dwd),.cpu_rdata(drd),
 .mem2_address(m2addr),.mem2_burstcount(m2count),.mem2_read(m2rd),.mem2_writedata(m2wd),.mem2_byteenable(8'hff),.mem2_write(m2wr),.mem2_readdata(m2data),.mem2_readdatavalid(m2valid),.mem2_waitrequest(m2wait),
 .DDRAM_CLK(dclk),.DDRAM_BUSY(dbusy),.DDRAM_BURSTCNT(dbc),.DDRAM_ADDR(daddr),.DDRAM_DOUT(ddout),.DDRAM_DOUT_READY(dready),.DDRAM_RD(dread),.DDRAM_DIN(ddin),.DDRAM_BE(dbe),.DDRAM_WE(dwrite));
ddr3_model dm(.clk(dclk),.busy(model_busy),.burstcnt(dbc),.addr(daddr),.dout(ddout),.dout_ready(dready),.rd(dread & !stall),.din(ddin),.be(dbe),.we(dwrite & !stall));
int errors=0,checks=0; int refreshes=0,slots=0,cpuslots=0;
// refreshes, and the longest run of SDRAM slots without one (8192 in 64 ms
// is one in 55 slots of 141 ns; a4k_sdram guarantees one in 32)
int since=0,maxgap=0;
always @(posedge s_clk) if(!s_cs && {s_ras,s_cas,s_we}==3'b001) begin refreshes++;since=0;end
always @(posedge sd.sysclk) if(sd.init_done && sd.sdram_state==0) begin since++;if(since>maxgap)maxgap=since;end
always @(posedge clk114) if(sd.init_done && sd.sdram_state==0) begin slots++;if(sq!=sa) cpuslots++;end

task automatic access(input[31:0] a,input bit w,input[3:0] b,input[31:0] v,input bit ln,input[1:0] bt,output[31:0] q);
 int n; @(negedge clk);addr=a[31:2];we=w;be=b;wd=v;line=ln;beat=bt;req=~req;
 n=0;do begin @(negedge clk);n++;if(n>2000)$fatal(1,"timeout addr=%h st=%d",a,lb.st);end while(ack!=req);
 q=rd;if(berr)$fatal(1,"berr at %h",a);
endtask
reg[31:0] q;
task automatic put(input[31:0] a,input[3:0] b,input[31:0] v); access(a,1,b,v,0,0,q);endtask
task automatic get(input[31:0] a,output[31:0] qout);access(a,0,15,0,0,0,qout);endtask
task automatic check(input[31:0] got,input[31:0] exp,input string msg);checks++;if(got!==exp)begin errors++;$display("FAIL %s got=%h expected=%h",msg,got,exp);end endtask
function automatic[31:0] merge(input[31:0] old,input[31:0] newval,input[3:0] b);
 merge=old;for(int i=0;i<4;i++)if(b[3-i])merge[31-i*8-:8]=newval[31-i*8-:8];
endfunction
function automatic[31:0] rev32(input[31:0] x);rev32={x[7:0],x[15:8],x[23:16],x[31:24]};endfunction
reg[31:0] phys;reg[63:0] raw;reg[23:0] cbases[5];int beforechip;
reg[31:0] bases[14]; reg[31:0] expected[4]; int r0,s0,c0;int totalerrors;
initial begin
 repeat(8)@(negedge clk);reset=0;repeat(300)@(negedge clk);
 put('h00e80044,12,'h10000000);put('h00e80044,12,'h20000000);put('h00e80044,12,'h40000000);
 bases[0]='h07000000;bases[1]='h073ffff0;bases[2]='h07400000;bases[3]='h077ffff0;bases[4]='h07800000;bases[5]='h07bffff0;bases[6]='h07fffff0;
 bases[7]='h10000000;bases[8]='h1ffffff0;bases[9]='h20000000;bases[10]='h27fffff0;bases[11]='h40000000;bases[12]='h407ffff0;bases[13]='h00dd4000;
 for(int f=0;f<2;f++)begin fast=f;
 for(int k=0;k<14;k++)begin
  for(int i=0;i<4;i++)begin expected[i]=32'h12345678 ^ (k<<20) ^ (i<<12);put(bases[k]+4*i,15,expected[i]);end
  for(int b=1;b<16;b++)for(int i=0;i<4;i++)begin
   automatic reg[31:0] v=32'h89abcdef^(b<<16)^(i<<8);
   put(bases[k]+4*i,4'(b),v);expected[i]=merge(expected[i],v,4'(b));
   for(int j=0;j<4;j++)begin get(bases[k]+4*j,q);check(q,expected[j],$sformatf("f=%d k=%d be=%x i=%d j=%d",f,k,b,i,j));end
  end
  // Inspect backing memory independently: catch mutually cancelling endian errors.
  phys=k<7 ? (32'h01000000 | (bases[k]&32'h00ffffff)) : k<9 ? (32'h30000000 | (bases[k]&32'h0fffffff)) : k<11 ? (32'h28000000 | (bases[k]&32'h07ffffff)) : k<13 ? (32'h27000000 | (bases[k]&32'h007fffff)) : (32'h27ff0000 | (bases[k]&32'hffff));
  for(int j=0;j<4;j++)begin
   if(k<7)check({sm.mem[(phys+4*j)/2],sm.mem[(phys+4*j)/2+1]},expected[j],"physical SDRAM lanes");
   else begin raw=dm.rd64((phys+4*j)/8);check((j%2)?raw[63:32]:raw[31:0],rev32(expected[j]),"physical DDR lanes");end
  end
  for(int start=0;start<4;start++)for(int bt=0;bt<4;bt++)begin
   access(bases[k]+4*((start+bt)%4),0,15,0,1,2'(bt),q);
   check(q,expected[(start+bt)%4],$sformatf("burst f=%d k=%d start=%d beat=%d",f,k,start,bt));
  end
 end end
 $display("MEMORY checks=%0d errors=%0d",checks,errors);totalerrors=errors;
 // ROM and overlay are read-only and share correct SDRAM backing.
 sm.mem['h780000/2]='h1234;sm.mem['h780002/2]='h5678;
 sm.mem['h700000/2]='habcd;sm.mem['h700002/2]='hef01;
 get('h00f80000,q);check(q,'h12345678,"kick map");put('h00f80000,15,'hffffffff);get('h00f80000,q);check(q,'h12345678,"kick write ignored");
 get('h00e00000,q);check(q,'habcdef01,"ext E map");get('h00f00000,q);check(q,'habcdef01,"ext F map");ovl=1;get(0,q);check(q,'h12345678,"overlay map");ovl=0;
 $display("ROM checks=%0d errors=%0d",checks,errors);
 // RTG register byte update must preserve the disabled lane.
 put('h40800108,12,'h02800000);put('h40800108,4,'h00110000);get('h40800108,q);check(q[31:16],16'h0211,"RTG hsize odd byte preserve high");
 put('h40800108,12,'h02800000);put('h40800108,8,'h03000000);get('h40800108,q);check(q[31:16],16'h0380,"RTG hsize even byte preserve low");
 $display("RTG errors=%0d",errors-totalerrors);
 // Separate colors, followed by legal 16-bit updates to either half.
 put('h40800400,15,'h00112233);put('h40800404,15,'h00445566);
 get('h40800400,q);check(q,'h00112233,"CLUT initial entry0");
 get('h40800404,q);check(q,'h00445566,"CLUT initial entry1");
 put('h40800400,12,'h00770000);get('h40800400,q);check(q,'h00772233,"CLUT red word preserves entry0 GB");
 put('h40800404,3,'h00008899);get('h40800404,q);check(q,'h00448899,"CLUT GB word preserves entry1 R");
 $display("CLUT tested; cumulative errors=%0d",errors);
 // The chip port's 16/32/64-bit transfers and wrapped SDRAM bursts.
 beforechip=checks;
 cbases[0]=0;cbases[1]='h1fc;cbases[2]='hffffc;cbases[3]='h3ffffc;cbases[4]='hfffffc;
 for(int k=0;k<5;k++)begin
  for(int j=0;j<4;j++)sm.mem[cbases[k]+j]=16'h1020+16'(j*'h2020);
  for(int lane=0;lane<4;lane++)begin
   @(negedge clk114);chipAddr=cbases[k]+lane;chipRW=1;chipDMA=0;chip32=1;
   repeat(40)@(negedge clk114);
   check(chipRD,16'h1020+16'(lane*'h2020),"chip first 16-bit word");
   check(chipRD2,16'h1020+16'(((lane+1)%4)*'h2020),"chip 32-bit second word");
   for(int j=0;j<3;j++)check(chip48[47-j*16-:16],16'h1020+16'(((lane+j+1)%4)*'h2020),"AGA 64-bit wrapped words");
  end
  for(int lane=0;lane<4;lane+=2)begin
   @(negedge clk114);chipAddr=cbases[k]+lane;chipRW=0;chipDMA=1;chip32=1;chipWR='hbeef;chipWR2='h1234;chipU=0;chipL=0;
   repeat(40)@(negedge clk114);chipRW=1;chip32=0;
   check({sm.mem[cbases[k]+lane],sm.mem[cbases[k]+lane+1]},'hbeef1234,"chip 32-bit writes");
  end
  for(int lane=0;lane<4;lane++)begin
   sm.mem[cbases[k]+lane]='h1234;
   @(negedge clk114);chipAddr=cbases[k]+lane;chipRW=0;chipDMA=1;chip32=0;chipWR='habcd;chipU=1;chipL=0;
   repeat(40)@(negedge clk114);chipRW=1;
   check(sm.mem[cbases[k]+lane],'h12cd,"chip lower byte");
   chipRW=0;chipU=0;chipL=1;repeat(40)@(negedge clk114);chipRW=1;
   check(sm.mem[cbases[k]+lane],'habcd,"chip upper byte");
  end
 end
 chipDMA=1;chipRW=1;chip32=0;chipL=0;chipU=0;
 $display("CHIP checks=%0d total_errors=%0d",checks-beforechip,errors);
 // Sustained local-bus posted stores. Record real refresh commands.
 r0=refreshes;s0=slots;c0=cpuslots;fast=1;maxgap=0;since=0;
 for(int i=0;i<5000;i++)put('h07010000+4*(i%64),15,i);
 $display("STREAM stores=5000 refreshes=%0d slots=%0d pending_slots=%0d",refreshes-r0,slots-s0,cpuslots-c0);
 checks++;if(maxgap>32)begin errors++;$display("FAIL refresh starved: %0d slots without one (at most 32)",maxgap);end
 wait(m2done);$display("DONE checks=%0d errors=%0d",checks,errors);if(errors)$fatal(1,"errors=%0d",errors);$finish;
end
initial begin #50000000;$fatal(1,"global timeout");end
endmodule
