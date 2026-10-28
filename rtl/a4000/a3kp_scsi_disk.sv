//============================================================================
//  a3kp_scsi_disk: the SCSI hard disks on the AA3000+'s bus
//
//  SCSI targets 0 and 1 (the MiSTer's primary IDE master and slave: the
//  hard disk images Main serves through ide.v), driving ide.v's CPU port as
//  an ATA host would.  A target answers its selection, then runs the SCSI-2
//  phase sequence itself: Message Out (the Identify, when the initiator
//  selected with ATN), Command, Data In or Out, Status, Message In (Command
//  Complete), and releases the bus.  It never disconnects.
//
//  The bus to the initiator (a3kp_sbic) is the SCSI bus's information
//  transfer handshake, one byte per REQ/ACK: the target sets the phase
//  (MSG, C/D, I/O), its byte for an In phase, and raises req; the initiator
//  answers with a one-clock ack and its byte for an Out phase.
//
//  Commands (SCSI-2, direct access): TEST UNIT READY, REZERO UNIT, REQUEST
//  SENSE, FORMAT UNIT, READ(6), WRITE(6), SEEK(6), INQUIRY, MODE SELECT(6),
//  RESERVE, RELEASE, MODE SENSE(6) (the block descriptor, pages 3 and 4
//  from the drive's ATA geometry), START STOP UNIT, SEND DIAGNOSTIC, PREVENT
//  ALLOW MEDIUM REMOVAL, READ CAPACITY, READ(10), WRITE(10), SEEK(10),
//  VERIFY, SYNCHRONIZE CACHE, READ DEFECT DATA (an empty list), MODE
//  SENSE(10).  Anything else: CHECK CONDITION, ILLEGAL REQUEST / INVALID
//  COMMAND OPERATION CODE.  LUNs other than 0 answer INQUIRY with peripheral
//  qualifier 3 and anything else with LOGICAL UNIT NOT SUPPORTED.
//
//  The disk is the ATA device: IDENTIFY DEVICE (its LBA28 capacity and CHS
//  geometry, read once per drive after a reset), READ SECTORS / WRITE
//  SECTORS (LBA28, up to 256 sectors per command).  The ATA data word is
//  little-endian on ide.v's side (as Budgie reads it): its low byte is the
//  first on the SCSI bus.
//============================================================================

module a3kp_scsi_disk
(
	input             clk,
	input             reset,          // the system reset (SCSI RST)

	// the SCSI bus, the initiator's side
	input             sel,            // selection, held until bsy or the initiator gives up
	input       [2:0] sel_id,
	input             atn,
	output reg        bsy = 1'b0,
	output reg  [2:0] phase,          // {MSG, C/D, I/O}
	output reg        req = 1'b0,
	output reg  [7:0] tdata,          // the target's byte (In phases)
	input             ack,            // one clock: the initiator took / gives a byte
	input       [7:0] idata,          // the initiator's byte (Out phases)

	// ide.v's CPU port
	output reg  [3:0] io_address,
	output reg        io_read = 1'b0,
	output reg        io_write = 1'b0,
	output reg [15:0] io_writedata,
	input      [15:0] io_readdata,
	input             io_nodata,      // fast-read data not delivered yet
	input       [1:0] present         // drives fitted (ide.v drive_en)
);

localparam [2:0] PH_DOUT = 3'b000, PH_DIN = 3'b001, PH_CMD = 3'b010, PH_STAT = 3'b011,
                 PH_MOUT = 3'b110, PH_MIN = 3'b111;

// sense keys / codes
localparam [3:0] SK_NONE = 4'h0, SK_NOT_READY = 4'h2, SK_MEDIUM = 4'h3, SK_ILLEGAL = 4'h5;

//----------------------------------------------------------------------------
// per drive: identified, capacity, geometry; the sense data
//----------------------------------------------------------------------------
reg        idv  [2];
reg [27:0] cap  [2];       // LBA28 sectors
reg [15:0] cyls [2];
reg  [7:0] hds  [2];
reg  [7:0] spt  [2];
reg  [3:0] skey [2];
reg  [7:0] sasc [2];

reg        tid;            // the selected target (0, 1)
reg  [2:0] lun;
reg  [7:0] cdb [12];
reg  [3:0] cdb_n, cdb_len;

wire [7:0] op = cdb[0];

// the command's numbers
wire [31:0] lba10 = {cdb[2], cdb[3], cdb[4], cdb[5]};
wire [20:0] lba6  = {cdb[1][4:0], cdb[2], cdb[3]};
wire [15:0] len10 = {cdb[7], cdb[8]};
wire  [8:0] len6  = (cdb[4] == 8'd0) ? 9'd256 : {1'b0, cdb[4]};

//----------------------------------------------------------------------------
// generated data-in: INQUIRY, REQUEST SENSE, READ CAPACITY, MODE SENSE,
// READ DEFECT DATA
//----------------------------------------------------------------------------
localparam [2:0] G_INQ = 3'd0, G_SENSE = 3'd1, G_CAP = 3'd2, G_MS6 = 3'd3, G_MS10 = 3'd4, G_DEFECT = 3'd5;
reg  [2:0] gen;
reg  [7:0] gpage;          // MODE SENSE's page code (6 bits; $3F all)

function automatic [7:0] str_byte(input [8*24-1:0] s, input [4:0] i);
	str_byte = s[8*(23 - i) +: 8];
endfunction

// INQUIRY, 36 bytes
function automatic [7:0] inq_byte(input [7:0] i, input lun_ok);
	case (i)
		8'd0:    inq_byte = lun_ok ? 8'h00 : 8'h7F;        // direct access / no such LU
		8'd2:    inq_byte = 8'h02;                        // SCSI-2
		8'd3:    inq_byte = 8'h02;                        // response format
		8'd4:    inq_byte = 8'd31;                        // additional length
		default: inq_byte = (i >= 8'd8 && i < 8'd32) ? str_byte("MiSTer  AA3000+ HDF     ", 5'(i - 8'd8)) :
		                    (i >= 8'd32 && i < 8'd36) ? ((i == 8'd32) ? "1" : (i == 8'd33) ? "." : (i == 8'd34) ? "0" : " ") :
		                    8'h00;
	endcase
endfunction

// MODE SENSE pages: the block descriptor, page 3 (format device), page 4
// (rigid disk geometry), 24 bytes each
function automatic [7:0] page_byte(input [7:0] pg, input [7:0] i, input [27:0] c, input [15:0] cy,
                                   input [7:0] hd, input [7:0] st);
	page_byte = 8'h00;
	if (pg == 8'h03) case (i)
		8'd0:  page_byte = 8'h03;
		8'd1:  page_byte = 8'h16;
		8'd3:  page_byte = hd;                // tracks per zone
		8'd10: page_byte = 8'h00;
		8'd11: page_byte = st;                // sectors per track
		8'd12: page_byte = 8'h02;             // 512 bytes per sector
		8'd13: page_byte = 8'h00;
		8'd15: page_byte = 8'h01;             // interleave 1
		8'd20: page_byte = 8'h40;             // HSEC: hard sectored
		default: ;
	endcase
	else if (pg == 8'h04) case (i)
		8'd0:  page_byte = 8'h04;
		8'd1:  page_byte = 8'h16;
		8'd3:  page_byte = cy[15:8];          // cylinders (24 bits)
		8'd4:  page_byte = cy[7:0];
		8'd5:  page_byte = hd;
		8'd20: page_byte = 8'h1C;             // 7200 rpm
		8'd21: page_byte = 8'h20;
		default: ;
	endcase
endfunction

// the generated byte i; its length
reg  [7:0] gbyte;
reg [15:0] glen;
always @(*) begin
	logic [27:0] c;
	logic [7:0]  bdl, pg, j;
	logic [15:0] hl, pl;
	c   = cap[tid];
	gbyte = 8'h00;
	glen  = 16'd0;
	case (gen)
		G_INQ: begin
			glen  = 16'd36;
			gbyte = inq_byte(gidx[7:0], lun == 3'd0 && present[tid]);
		end
		G_SENSE: begin
			glen = 16'd18;
			case (gidx[7:0])
				8'd0:  gbyte = 8'h70;
				8'd2:  gbyte = {4'h0, (lun != 3'd0) ? SK_ILLEGAL : skey[tid]};
				8'd7:  gbyte = 8'd10;
				8'd12: gbyte = (lun != 3'd0) ? 8'h25 : sasc[tid];
				default: gbyte = 8'h00;
			endcase
		end
		G_CAP: begin
			logic [31:0] last;
			last = {4'd0, c} - 32'd1;
			glen = 16'd8;
			case (gidx[2:0])
				3'd0: gbyte = last[31:24];
				3'd1: gbyte = last[23:16];
				3'd2: gbyte = last[15:8];
				3'd3: gbyte = last[7:0];
				3'd6: gbyte = 8'h02;          // 512-byte blocks
				default: gbyte = 8'h00;
			endcase
		end
		G_MS6, G_MS10: begin
			// header (4 or 8 bytes), block descriptor (8), the pages
			hl  = (gen == G_MS6) ? 16'd4 : 16'd8;
			bdl = cdb[1][3] ? 8'd0 : 8'd8;    // DBD
			pg  = gpage & 8'h3F;
			pl  = (pg == 8'h3F) ? 16'd48 : (pg == 8'h03 || pg == 8'h04) ? 16'd24 : 16'd0;
			glen = hl + {8'd0, bdl} + pl;
			if (gidx < hl) begin
				if (gen == G_MS6) case (gidx[1:0])
					2'd0: gbyte = 8'(glen - 16'd1);
					2'd3: gbyte = bdl;
					default: gbyte = 8'h00;
				endcase
				else case (gidx[2:0])
					3'd1: gbyte = 8'(glen - 16'd2);
					3'd7: gbyte = bdl;
					default: gbyte = 8'h00;
				endcase
			end
			else if (gidx < hl + {8'd0, bdl}) begin
				j = 8'(gidx - hl);
				case (j[2:0])
					3'd1: gbyte = {4'd0, c[27:24]};
					3'd2: gbyte = c[23:16];
					3'd3: gbyte = c[15:8];
					3'd4: gbyte = c[7:0];
					3'd6: gbyte = 8'h02;
					default: gbyte = 8'h00;
				endcase
			end
			else begin
				j = 8'(gidx - hl - {8'd0, bdl});
				if (pg == 8'h3F) gbyte = (j < 8'd24) ? page_byte(8'h03, j, c, cyls[tid], hds[tid], spt[tid])
				                                     : page_byte(8'h04, j - 8'd24, c, cyls[tid], hds[tid], spt[tid]);
				else gbyte = page_byte(pg, j, c, cyls[tid], hds[tid], spt[tid]);
			end
		end
		G_DEFECT: begin
			// an empty defect list in the requested format
			glen = 16'd4;
			gbyte = (gidx[1:0] == 2'd1) ? {3'b000, cdb[2][4:0]} : 8'h00;
		end
		default: ;
	endcase
end

//----------------------------------------------------------------------------
// the target's sequence
//----------------------------------------------------------------------------
localparam [5:0]
	T_FREE   = 6'd0,  T_MOUT  = 6'd1,  T_CMD   = 6'd2,  T_EXEC  = 6'd3,
	T_GEN    = 6'd4,  T_STAT  = 6'd5,  T_MIN   = 6'd6,  T_END   = 6'd7,
	T_ID     = 6'd8,  T_RW    = 6'd9,  T_RSEC  = 6'd10, T_RWORD = 6'd11, T_RB0 = 6'd12, T_RB1 = 6'd13,
	T_WSEC   = 6'd14, T_WB0   = 6'd15, T_WB1   = 6'd16, T_WWORD = 6'd17, T_WDONE = 6'd18,
	T_ATAW   = 6'd19, T_ATAR  = 6'd20, T_POLL  = 6'd21, T_IDW   = 6'd22, T_IDDONE = 6'd23,
	T_CHUNK  = 6'd24, T_SINK = 6'd25;

reg  [5:0] st = T_FREE;
reg  [5:0] ret;            // where an ATA helper returns
reg [15:0] gidx;
reg [15:0] glimit;         // the allocation length
reg  [7:0] status;
reg        is_write;
reg [27:0] rw_lba;         // the next sector
reg [16:0] rw_left;        // sectors still to move
reg  [8:0] rw_chunk;       // sectors in this ATA command
reg  [8:0] rw_sec;         // sectors of the chunk still to move
reg  [8:0] rw_word;        // words of the sector still to move
reg [15:0] word;
reg  [7:0] wb0;
reg  [2:0] aw_i;           // the ATA register list step
reg  [7:0] ata_cmd;
reg  [1:0] rcnt;           // ATA read: clocks since the strobe
reg  [7:0] astat;          // the ATA status read
reg  [7:0] idw;            // IDENTIFY: words read
reg  [4:0] pdly;           // the status settles before it is read (ATA: 400 ns after a command or a block)

// the selection: a fitted target, LUN checks come with the Identify
wire sel_me = sel && !bsy && sel_id[2:1] == 2'b00 && present[sel_id[0]];

// the ATA task file for the transfer: device, count, LBA, command
function automatic [3:0] aw_reg(input [2:0] i);
	case (i)
		3'd0: aw_reg = 4'd6;
		3'd1: aw_reg = 4'd2;
		3'd2: aw_reg = 4'd3;
		3'd3: aw_reg = 4'd4;
		3'd4: aw_reg = 4'd5;
		default: aw_reg = 4'd7;
	endcase
endfunction

task automatic set_sense(input [3:0] k, input [7:0] asc);
	skey[tid] <= k;
	sasc[tid] <= asc;
endtask

always @(posedge clk) begin
	io_read  <= 1'b0;
	io_write <= 1'b0;

	if (reset) begin
		st    <= T_FREE;
		bsy   <= 1'b0;
		req   <= 1'b0;
		idv[0] <= 1'b0; idv[1] <= 1'b0;
		skey[0] <= SK_NONE; skey[1] <= SK_NONE;
		sasc[0] <= 8'h00;   sasc[1] <= 8'h00;
	end
	else case (st)
		T_FREE: begin
			req <= 1'b0;
			if (sel_me) begin
				bsy   <= 1'b1;
				tid   <= sel_id[0];
				lun   <= 3'd0;
				cdb_n <= 4'd0;
				st    <= atn ? T_MOUT : T_CMD;
			end
		end

		// Message Out: the Identify (and whatever else the initiator sends
		// while ATN stays asserted: taken and ignored)
		T_MOUT: begin
			phase <= PH_MOUT;
			req   <= 1'b1;
			if (ack) begin
				req <= 1'b0;
				if (idata[7]) lun <= idata[2:0];
				if (!atn) st <= T_CMD;
			end
		end

		T_CMD: begin
			phase <= PH_CMD;
			req   <= 1'b1;
			if (ack) begin
				logic [3:0] n;
				req <= 1'b0;
				cdb[cdb_n] <= idata;
				n = cdb_n + 1'd1;
				if (cdb_n == 4'd0)
					cdb_len <= (idata[7:5] == 3'd1 || idata[7:5] == 3'd2) ? 4'd10 : (idata[7:5] == 3'd5) ? 4'd12 : 4'd6;
				cdb_n <= n;
				if (cdb_n != 4'd0 && n == cdb_len) st <= T_EXEC;
			end
		end

		T_EXEC: begin
			status <= 8'h00;
			gidx   <= 16'd0;
			if (op == 8'h12) begin
				// INQUIRY (any LUN)
				gen <= G_INQ; glimit <= {8'd0, cdb[4]}; st <= T_GEN;
			end
			else if (op == 8'h03) begin
				// REQUEST SENSE (any LUN): the sense is then cleared
				gen <= G_SENSE; glimit <= (cdb[4] == 8'd0) ? 16'd4 : {8'd0, cdb[4]}; st <= T_GEN;
			end
			else if (lun != 3'd0) begin
				status <= 8'h02;
				st     <= T_STAT;
			end
			else if (!idv[tid]) begin
				// identify the drive first
				ret      <= T_EXEC;
				ata_cmd  <= 8'hEC;
				aw_i     <= 3'd0;
				st       <= T_ID;
			end
			else begin
				set_sense(SK_NONE, 8'h00);
				case (op)
					8'h00, 8'h01, 8'h04, 8'h0B, 8'h16, 8'h17, 8'h1B, 8'h1D, 8'h1E, 8'h2B, 8'h2F, 8'h35:
						st <= T_STAT;                           // nothing to move
					// MODE SELECT: the parameter list is taken and ignored
					8'h15: begin glimit <= {8'd0, cdb[4]}; st <= T_SINK; end
					8'h55: begin glimit <= len10;          st <= T_SINK; end
					8'h1A: begin gen <= G_MS6;  gpage <= cdb[2]; glimit <= {8'd0, cdb[4]}; st <= T_GEN; end
					8'h5A: begin gen <= G_MS10; gpage <= cdb[2]; glimit <= len10;          st <= T_GEN; end
					8'h25: begin gen <= G_CAP;  glimit <= 16'd8;                           st <= T_GEN; end
					8'h37: begin gen <= G_DEFECT; glimit <= len10;                         st <= T_GEN; end
					8'h08, 8'h0A, 8'h28, 8'h2A: begin
						logic [31:0] l;
						logic [16:0] n;
						l = (op[5]) ? lba10 : {11'd0, lba6};
						n = (op[5]) ? {1'b0, len10} : {8'd0, len6};
						is_write <= op[1];
						if ({1'b0, l} + {16'd0, n} > {5'd0, cap[tid]}) begin
							set_sense(SK_ILLEGAL, 8'h21);           // LBA out of range
							status <= 8'h02;
							st     <= T_STAT;
						end
						else begin
							rw_lba  <= l[27:0];
							rw_left <= n;
							st      <= T_CHUNK;
						end
					end
					default: begin
						set_sense(SK_ILLEGAL, 8'h20);              // invalid command operation code
						status <= 8'h02;
						st     <= T_STAT;
					end
				endcase
			end
		end

		// a generated Data In: up to the allocation length
		T_GEN: begin
			if (gidx >= glen || gidx >= glimit) begin
				req <= 1'b0;
				if (gen == G_SENSE && lun == 3'd0) set_sense(SK_NONE, 8'h00);
				st <= T_STAT;
			end
			else begin
				phase <= PH_DIN;
				tdata <= gbyte;
				req   <= 1'b1;
				if (ack && req) begin
					req  <= 1'b0;
					gidx <= gidx + 1'd1;
				end
			end
		end

		// a Data Out the target ignores
		T_SINK: begin
			if (gidx >= glimit) begin
				req <= 1'b0;
				st  <= T_STAT;
			end
			else begin
				phase <= PH_DOUT;
				req   <= 1'b1;
				if (ack && req) begin
					req  <= 1'b0;
					gidx <= gidx + 1'd1;
				end
			end
		end

		T_STAT: begin
			phase <= PH_STAT;
			tdata <= status;
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				st  <= T_MIN;
			end
		end

		T_MIN: begin
			phase <= PH_MIN;
			tdata <= 8'h00;                               // COMMAND COMPLETE
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				st  <= T_END;
			end
		end

		T_END: begin
			bsy <= 1'b0;
			st  <= T_FREE;
		end

		//--------------------------------------------------------------------
		// READ / WRITE: ATA commands of up to 256 sectors
		//--------------------------------------------------------------------
		T_CHUNK: begin
			if (rw_left == 17'd0) st <= T_STAT;
			else begin
				rw_chunk <= (rw_left >= 17'd256) ? 9'd256 : rw_left[8:0];
				rw_sec   <= (rw_left >= 17'd256) ? 9'd256 : rw_left[8:0];
				ata_cmd  <= is_write ? 8'h30 : 8'h20;
				aw_i     <= 3'd0;
				ret      <= is_write ? T_WSEC : T_RSEC;
				st       <= T_ATAW;
			end
		end

		// the task file, one register a step
		T_ATAW: begin
			io_address <= aw_reg(aw_i);
			io_write   <= 1'b1;
			case (aw_i)
				3'd0: io_writedata <= {8'h00, 3'b111, tid, (ata_cmd == 8'hEC) ? 4'd0 : rw_lba[27:24]};   // LBA, the drive
				3'd1: io_writedata <= {8'h00, rw_chunk[7:0]};
				3'd2: io_writedata <= {8'h00, rw_lba[7:0]};
				3'd3: io_writedata <= {8'h00, rw_lba[15:8]};
				3'd4: io_writedata <= {8'h00, rw_lba[23:16]};
				default: io_writedata <= {8'h00, ata_cmd};
			endcase
			// IDENTIFY needs only the device and the command
			if (ata_cmd == 8'hEC && aw_i == 3'd0) aw_i <= 3'd5;
			else aw_i <= aw_i + 1'd1;
			if (aw_i == 3'd5) begin
				rcnt <= 2'd0;
				pdly <= 5'd16;
				st   <= T_POLL;
			end
		end

		// wait for BSY to drop: then DRQ (data) or ERR
		T_POLL: begin
			if (pdly != 5'd0) pdly <= pdly - 1'd1;
			else if (rcnt == 2'd0) begin
				io_address <= 4'd7;
				io_read    <= 1'b1;
				rcnt       <= 2'd1;
			end
			else if (rcnt == 2'd1) rcnt <= 2'd2;
			else begin
				rcnt  <= 2'd0;
				astat <= io_readdata[7:0];
				if (!io_readdata[7]) begin
					if (io_readdata[0]) begin
						// ERR: the command failed
						req <= 1'b0;
						if (ata_cmd == 8'hEC) begin
							set_sense(SK_NOT_READY, 8'h04);
							status <= 8'h02;
							st     <= T_STAT;
						end
						else begin
							set_sense(SK_MEDIUM, is_write ? 8'h0C : 8'h11);   // write error / unrecovered read error
							status <= 8'h02;
							st     <= T_STAT;
						end
					end
					else if (io_readdata[3]) begin
						rw_word <= 9'd256;
						st      <= ret;
					end
					else if (ata_cmd != 8'hEC && rw_sec == 9'd0) begin
						// the chunk is done
						rw_lba  <= rw_lba + {19'd0, rw_chunk};
						rw_left <= rw_left - {8'd0, rw_chunk};
						st      <= T_CHUNK;
					end
				end
			end
		end

		// IDENTIFY DEVICE: words 1 (cylinders), 3 (heads), 6 (sectors),
		// 60-61 (LBA28 sectors)
		T_ID: begin
			ret     <= T_IDW;
			idw     <= 8'd0;
			rw_sec  <= 9'd1;
			st      <= T_ATAW;
		end
		T_IDW: begin
			if (rw_word == 9'd0) begin
				idv[tid] <= 1'b1;
				st       <= T_IDDONE;
			end
			else if (rcnt == 2'd0) begin
				if (!io_nodata) begin
					io_address <= 4'd0;
					io_read    <= 1'b1;
					rcnt       <= 2'd1;
				end
			end
			else if (rcnt == 2'd1) rcnt <= 2'd2;
			else begin
				rcnt <= 2'd0;
				case (idw)
					8'd1:  cyls[tid] <= io_readdata;
					8'd3:  hds[tid]  <= io_readdata[7:0];
					8'd6:  spt[tid]  <= io_readdata[7:0];
					8'd60: cap[tid][15:0]  <= io_readdata;
					8'd61: cap[tid][27:16] <= io_readdata[11:0];
					default: ;
				endcase
				idw     <= idw + 1'd1;
				rw_word <= rw_word - 1'd1;
			end
		end
		T_IDDONE: begin
			// wait for the device to settle (BSY clear) and go on with the command
			rcnt <= 2'd0;
			st   <= T_EXEC;
		end

		// Data In: a sector's 256 words, each two bytes, low byte first
		T_RSEC: begin
			if (rw_word == 9'd0) begin
				rw_sec <= rw_sec - 1'd1;
				rcnt   <= 2'd0;
				pdly   <= 5'd16;
				st     <= T_POLL;
			end
			else st <= T_RWORD;
		end
		T_RWORD: begin
			if (rcnt == 2'd0) begin
				if (!io_nodata) begin
					io_address <= 4'd0;
					io_read    <= 1'b1;
					rcnt       <= 2'd1;
				end
			end
			else if (rcnt == 2'd1) rcnt <= 2'd2;
			else begin
				rcnt    <= 2'd0;
				word    <= io_readdata;
				rw_word <= rw_word - 1'd1;
				st      <= T_RB0;
			end
		end
		T_RB0: begin
			phase <= PH_DIN;
			tdata <= word[7:0];
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				st  <= T_RB1;
			end
		end
		T_RB1: begin
			phase <= PH_DIN;
			tdata <= word[15:8];
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				st  <= T_RSEC;
			end
		end

		// Data Out: two bytes make a word, a sector's 256 words
		T_WSEC: begin
			if (rw_word == 9'd0) begin
				rw_sec <= rw_sec - 1'd1;
				rcnt   <= 2'd0;
				pdly   <= 5'd16;
				st     <= T_POLL;
			end
			else st <= T_WB0;
		end
		T_WB0: begin
			phase <= PH_DOUT;
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				wb0 <= idata;
				st  <= T_WB1;
			end
		end
		T_WB1: begin
			phase <= PH_DOUT;
			req   <= 1'b1;
			if (ack && req) begin
				req <= 1'b0;
				io_address   <= 4'd0;
				io_writedata <= {idata, wb0};
				io_write     <= 1'b1;
				rw_word      <= rw_word - 1'd1;
				st           <= T_WSEC;
			end
		end

		default: st <= T_FREE;
	endcase
end


`ifdef SCSI_DEBUG
reg [5:0] dbg_st_d = 6'd0;
always @(posedge clk) begin
	dbg_st_d <= 6'(st);
	if (6'(st) != dbg_st_d) $display("[disk] %t st %0d -> %0d", $time, dbg_st_d, st);
end
`endif

endmodule
