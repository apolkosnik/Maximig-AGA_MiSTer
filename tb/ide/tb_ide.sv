`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg reset=1,fast=0,ide_rst=0; // ide_rst: the machine's RST (a warm reset, RESET), which resets the IDE but not Budgie
reg sb_req=0;wire sb_ack;reg[23:2]sb_addr=0;reg sb_we=0;reg[3:0]sb_be=0;reg[31:0]sb_wdata=0;wire[31:0]sb_rdata;
wire[3:0]ia;wire ir,iw;wire[15:0]idw;wire[31:0]idr;wire nodata,irq,drq;wire[1:0]present;wire[2:0]request;
reg[3:0]ma=0;reg mw=0,mr=0;reg[15:0]mdw=0;wire[15:0]mdr;
a4k_budgie bridge(.clk(clk),.reset(reset),.fast(fast),.clk7_en(1'b0),.cck(1'b0),.sb_req(sb_req),.sb_ack(sb_ack),.sb_tgt(3'd4),.sb_addr(sb_addr),.sb_we(sb_we),.sb_be(sb_be),.sb_wdata(sb_wdata),.sb_rdata(sb_rdata),.cpu_dtack_n(1'b1),.cpu_din(16'd0),.cpu_din2(16'd0),.chip32_en(1'b0),.rtc_rdata(4'd0),.ide_addr(ia),.ide_rd(ir),.ide_wr(iw),.ide_wdata(idw),.ide_rdata(idr[15:0]),.ide_nodata(nodata),.ide_irq(irq),.ide_reset(reset|ide_rst),.ide_present(present),.a2065_din(16'd0),.a2065_nrdy(1'b0),.tocc_din(16'd0));
ide dut(.clk(clk),.rst_n(~(reset|ide_rst)),.irq(irq),.drq(drq),.use_fast(1'b1),.no_data(nodata),.drive_en(present),.io_address(ia),.io_read(ir),.io_readdata(idr),.io_write(iw),.io_writedata({16'd0,idw}),.io_32(1'b0),.io_wait(),.request(request),.mgmt_address(ma),.mgmt_write(mw),.mgmt_writedata(mdw),.mgmt_read(mr),.mgmt_readdata(mdr));
integer checked=0,failures=0;
function automatic[15:0] pattern(input integer n,input integer seed);pattern=16'(n*73)^16'(seed);endfunction
function automatic[15:0] swap(input[15:0]n);swap={n[7:0],n[15:8]};endfunction
task hwrite(input[3:0]a,input[15:0]d);begin
 @(negedge clk);ma=a;mdw=d;mw=1;
 @(negedge clk);mw=0;repeat(4)@(negedge clk);
end endtask
task hread(input[3:0]a,output[15:0]d);begin
 @(negedge clk);ma=a;repeat(4)@(negedge clk);mr=1;
 @(posedge clk);#1;d=mdr;
 @(negedge clk);mr=0;repeat(4)@(negedge clk);
end endtask
task beat(input[23:0]a,input we,input[3:0]be,input[31:0]d,output[31:0]q);integer t;begin
 @(negedge clk);sb_addr=a[23:2];sb_we=we;sb_be=be;sb_wdata=d;sb_req=~sb_req;
 t=0;while(sb_ack!=sb_req && t<10000)begin @(negedge clk);t=t+1;end
 if(t>=10000)$fatal(1,"beat timed out addr=%h req=%b nodata=%b",a,request,nodata);
 q=sb_rdata;repeat(2)@(negedge clk);
end endtask
task cwrite8(input[23:0]a,input[7:0]d);reg[31:0]q;begin beat(a,1,4'b1000>>a[1:0],32'(d)<<(24-8*a[1:0]),q);end endtask
task cread8(input[23:0]a,output[7:0]d);reg[31:0]q;begin beat(a,0,4'b1000>>a[1:0],0,q);d=8'(q>>(24-8*a[1:0]));end endtask
task cwrite16(input[15:0]d);reg[31:0]q;begin beat(24'hdd2020,1,4'b1100,{d,16'd0},q);end endtask
task cread16(output[15:0]d);reg[31:0]q;begin beat(24'hdd2020,0,4'b1100,0,q);d=q[31:16];end endtask
task check(input bit ok,input string msg);begin if(!ok)begin $display("CONTROL FAIL: %s",msg);failures=failures+1;end end endtask
task load_data(input integer words,input integer seed);begin for(integer n=0;n<words;n=n+1)hwrite(15,pattern(n,seed));end endtask
task read_data(input integer words,input integer seed,input bit longs);reg[15:0]w;reg[31:0]q;begin
 for(integer n=0;n<words;n=n+(longs?2:1))begin
  if(longs)begin beat(24'hdd2020,0,15,0,q);check(q=={swap(pattern(n,seed)),swap(pattern(n+1,seed))},$sformatf("longword n=%0d got=%h",n,q));checked=checked+2;end
  else begin cread16(w);check(w==swap(pattern(n,seed)),$sformatf("word n=%0d got=%h expected=%h",n,w,swap(pattern(n,seed))));checked=checked+1;end
 end
end endtask
reg[7:0]v;reg[15:0]w;reg[31:0]q;
initial begin
 repeat(8)@(negedge clk);reset=0;
 cread8(24'hdd203e,v);check(v==8'h7f,"no-drive status");
 cread8(24'hdd3020,v);check(v==0,"cold-reset interrupt status");
 hwrite(6,16'h0009);hwrite(5,16'h50a0);
 cread8(24'hdd203e,v);check(v==8'h50,"present ready status");
 cwrite8(24'hdd2026,8'h5a);hread(0,w);check(w[15:8]==8'h5a,"feature byte lane");
 cwrite8(24'hdd202a,8'h37);cread8(24'hdd202a,v);check(v==8'h37,"sector count byte lane");
 cwrite8(24'hdd202e,8'h12);cwrite8(24'hdd2032,8'h34);cwrite8(24'hdd2036,8'h56);
 hread(1,w);check(w==16'h1237,"HPS sector/count register packing");hread(2,w);check(w==16'h5634,"HPS cylinder packing");
 // Normal PIO reads: word/longword accesses, both motherboard timing settings.
 for(integer mode=0;mode<2;mode=mode+1)for(integer lng=0;lng<2;lng=lng+1)begin
  fast=mode;cwrite8(24'hdd203e,8'h20);check(request==4,"read command request");
  load_data(256,16'ha123);hwrite(0,1);hwrite(5,16'h5ea0);
  check(irq,"read data-ready interrupt");cread8(24'hdd303a,v);check(irq && v==8'h58,"alternate status preserves IRQ");
  cread8(24'hdd203e,v);check(!irq && v==8'h58,"status acknowledges IRQ");
  read_data(256,16'ha123,lng);check(!drq && request==0,"last read completes without another HPS request");
 end
 // PIO writes and the CPU-to-HPS byte order, including the largest HPS block.
 for(integer blocks=1;blocks<=32;blocks=blocks*32)begin
  cwrite8(24'hdd203e,8'h30);hwrite(0,blocks);hwrite(5,16'h58a0);
  for(integer n=0;n<blocks*256;n=n+1)cwrite16(swap(pattern(n,16'h5a96)));
  check(request==5 && !drq,"write block requests HPS service");
  for(integer n=0;n<blocks*256;n=n+1)begin hread(15,w);check(w==pattern(n,16'h5a96),$sformatf("write data n=%0d got=%h",n,w));checked=checked+1;end
  hwrite(5,16'h54a0);cread8(24'hdd203e,v);check(v==8'h50 && !irq,"write completion status and IRQ ack");
 end
 // HPS streams after announcing DRQ. Stall the producer to exercise no_data.
 cwrite8(24'hdd203e,8'h20);hwrite(0,1);hwrite(5,16'h7ea0);check(nodata,"fast read initially stalls");
 fork
  begin read_data(256,16'hb42d,0);end
  begin repeat(50)@(negedge clk);for(integer n=0;n<256;n=n+1)begin if(n%17==0)repeat(30)@(negedge clk);hwrite(15,pattern(n,16'hb42d));end end
 join
 check(!drq && request==0,"streamed read completed");
 // Two DRQ blocks in one command, with a new HPS response between them.
 cwrite8(24'hdd203e,8'h20);hread(0,w); // HPS command-register fetch resets its buffer cursor
 for(integer blocknum=0;blocknum<2;blocknum=blocknum+1)begin
  load_data(256,16'h7910+blocknum);hwrite(0,1);hwrite(5,blocknum?16'h5ea0:16'h5ca0);
  cread8(24'hdd203e,v);read_data(256,16'h7910+blocknum,0);
  check(!drq && request==(blocknum?0:5),"multi-block read handoff");
 end
 // ATAPI: six-word packet out, three-word data in, then explicit completion.
 cwrite8(24'hdd203e,8'ha0);hwrite(0,16'h0080);hwrite(4,6);hwrite(5,16'h48a0);
 for(integer n=0;n<6;n=n+1)cwrite16(swap(pattern(n,16'h9012)));
 check(request==5 && !drq,"ATAPI packet completion request");
 for(integer n=0;n<6;n=n+1)begin hread(15,w);check(w==pattern(n,16'h9012),"ATAPI packet data");checked=checked+1;end
 hwrite(0,16'h0080);hwrite(4,3);load_data(3,16'h2468);hwrite(5,16'h4ca0);
 cread8(24'hdd203e,v);read_data(3,16'h2468,0);check(request==5 && !drq,"ATAPI odd-word phase completion");
 hwrite(5,16'h44a0);cread8(24'hdd203e,v);check(v==8'h40 && !irq,"ATAPI final status");
 $display("PASS CONTROLS: %0d transferred words, status/alternate-status IRQ semantics, byte order, normal/fast timings, 32-sector write, streaming backpressure, multi-block handoffs and ATAPI packet/data phases; failures=%0d",checked,failures);
 if(failures)$fatal(1,"positive control failed");
 // Fault 1: mask an already asserted interrupt.
 cwrite8(24'hdd303a,0);hwrite(5,16'h54a0);check(irq,"IRQ before masking");check(bridge.irq_seen,"the interrupt status latched");
 cwrite8(24'hdd303a,2);check(!irq,"nIEN=1 releases an asserted INTRQ");
 cwrite8(24'hdd303a,0);check(irq,"nIEN=0 again: the interrupt is still pending");
 cwrite8(24'hdd303a,2);
 cread8(24'hdd203e,v);hwrite(5,16'h54a0);check(!irq,"new interrupt is masked normally");
 // Fault 2: normal SRST+nIEN sequence must retain nIEN after SRST drops.
 cwrite8(24'hdd303a,6);repeat(600)@(negedge clk);cwrite8(24'hdd303a,2);
 hwrite(5,16'h50a0);cwrite8(24'hdd203e,8'he7);hwrite(5,16'h54a0);
 check(!irq && dut.disable_irq,"nIEN survives SRST (Device Control 06 then 02)");
 // Fault 3: the motherboard interrupt-status latch survives a hardware reset.
 cread8(24'hdd203e,v);check(!irq,"IRQ cleared before reset");
 @(negedge clk);ide_rst=1;repeat(8)@(negedge clk);ide_rst=0;hwrite(5,16'h50a0);
 cread8(24'hdd3020,v);check(v==0 && !irq,"a warm reset clears the interrupt status");
 cread8(24'hdd3020,v);check(v==0,"interrupt-status read clears latch");
 // Optional LBA48 configuration: unlike normal MiSTer HDD config, HOB enabled.
 hwrite(6,16'h000b);cwrite8(24'hdd202a,8'h12);cwrite8(24'hdd202a,8'h34);cwrite8(24'hdd303a,8'h80);
 cread8(24'hdd202a,v);check(v==8'h12,"HOB selects high byte");
 cwrite8(24'hdd2026,8'h5a);cread8(24'hdd202a,v);
 check(v==8'h34,"a Command Block write clears HOB");
 if(failures)$fatal(1,"failures=%0d",failures);
 $display("PASS: nIEN, SRST, the interrupt status on reset, HOB");
 $finish;
end
endmodule
