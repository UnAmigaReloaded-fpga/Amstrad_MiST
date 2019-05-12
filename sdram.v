//
// sdram.v
//
// sdram controller implementation
// Copyright (c) 2018 Sorgelig
//
// Based on sdram module by Till Harbaum
// 
// This source file is free software: you can redistribute it and/or modify 
// it under the terms of the GNU General Public License as published 
// by the Free Software Foundation, either version 3 of the License, or 
// (at your option) any later version. 
// 
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of 
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the 
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License 
// along with this program.  If not, see <http://www.gnu.org/licenses/>. 
//

module sdram
(

	// interface to the MT48LC16M16 chip
	inout  reg [15:0] SDRAM_DQ,   // 16 bit bidirectional data bus
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output reg        SDRAM_DQML, // byte mask
	output reg        SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output reg        SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CKE,

	// cpu/chipset interface
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz
	input             clkref,		// reference clock to sync to
	
	input       [1:0] bank,
	input       [7:0] din,			// data input from chipset/cpu
	output      [7:0] dout,			// data output to chipset/cpu
	input      [22:0] addr,       // 25 bit byte address
	input             oe,         // cpu/chipset requests read
	input             we,         // cpu/chipset requests write

	output reg [15:0] vram_dout,
	input      [22:0] vram_addr,

	input      [22:0] tape_addr,
	input       [7:0] tape_din,
	output reg  [7:0] tape_dout,
	input             tape_wr,
	input             tape_rd,
	output reg        tape_ack
);

assign SDRAM_CKE = ~init;
assign dout = oe ? ram_dout : 8'hFF;

// no burst configured
localparam RASCAS_DELAY   = 3'd2;   // tRCD=20ns -> 2 cycles@64MHz
localparam BURST_LENGTH   = 3'b000; // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH}; 

localparam STATE_IDLE  = 3'd0;   // first state in cycle
localparam STATE_START = 3'd1;   // state in which a new command can be started
localparam STATE_CONT  = STATE_START  + RASCAS_DELAY; // 3 command can be continued
localparam STATE_LAST  = 3'd7;   // last state in cycle

reg  [2:0] q;
reg [22:0] a;
reg        wr;
reg        ram_req=0;
reg        vram_req=0;
reg        tape_req=0;

// access manager
always @(posedge clk) begin
	reg [22:0] old_addr;
	reg old_rd, old_we, old_ref;

	old_rd<=oe;
	old_we<=we;
	old_ref<=clkref;

	if(q==STATE_IDLE) begin
		ram_req <= 0;
		vram_req <= 0;
		tape_req <= 0;
		wr <= 0;

		if((~old_rd & oe) | (~old_we & we)) begin
			ram_req <= 1;
			wr <= we;
			a <= addr;
		end
		else if(old_addr[15:1] != vram_addr[15:1]) begin
			vram_req <= 1;
			old_addr <= vram_addr;
			a <= vram_addr;
		end
		else begin
			// The IO Controller advances in about 5-6 SDRAM cycles, thus
			// no tape read/write should skipped even in this lowest priority
			if(tape_rd | tape_wr) begin
				tape_req <= 1;
				wr <= tape_wr;
				a <= tape_addr;
			end
		end
	end

	q <= q + 3'd1;
	if(~old_ref & clkref) q <= 0;
end

localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

// initialization 
reg [1:0] mode;
always @(posedge clk) begin
	reg [4:0] reset=5'h1f;
	reg init_old=0;
	init_old <= init;

	if(init_old & ~init) reset <= 5'h1f;
	else if(q == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
		end
		else mode <= MODE_NORMAL;
	end
end

localparam CMD_INHIBIT         = 4'b1111;
localparam CMD_NOP             = 4'b0111;
localparam CMD_ACTIVE          = 4'b0011;
localparam CMD_READ            = 4'b0101;
localparam CMD_WRITE           = 4'b0100;
localparam CMD_BURST_TERMINATE = 4'b0110;
localparam CMD_PRECHARGE       = 4'b0010;
localparam CMD_AUTO_REFRESH    = 4'b0001;
localparam CMD_LOAD_MODE       = 4'b0000;

reg [7:0] ram_dout;

// SDRAM state machines
always @(posedge clk) begin
	casex({ram_req|vram_req|tape_req,wr,mode,q})
		{2'b1X, MODE_NORMAL, STATE_START}: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACTIVE;
		{2'b11, MODE_NORMAL, STATE_CONT }: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_WRITE;
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
		{2'b0X, MODE_NORMAL, STATE_START}: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;

		                          default: {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_INHIBIT;
	endcase

	casex({ram_req|vram_req|tape_req,mode,q})
		{1'b1,  MODE_NORMAL, STATE_START}: SDRAM_A <= a[21:9];
		{1'b1,  MODE_NORMAL, STATE_CONT }: SDRAM_A <= {4'b0010, a[22], a[8:1]};

		// init
		{1'bX,     MODE_LDM, STATE_START}: SDRAM_A <= MODE;
		{1'bX,     MODE_PRE, STATE_START}: SDRAM_A <= 13'b0010000000000;

		                          default: SDRAM_A <= 13'b0000000000000;
	endcase

	if(q == STATE_START) begin
		SDRAM_BA <= (mode == MODE_NORMAL) ? (tape_req ? 2'b10 : bank) : 2'b00;
		SDRAM_DQ <= wr ? (tape_req ? {tape_din, tape_din} : {din, din}) : 16'bZZZZZZZZZZZZZZZZ;
		{SDRAM_DQMH,SDRAM_DQML} <= {~a[0] & wr,a[0] & wr};
		if(ram_req & wr) ram_dout <= din;
	end

	if (q == STATE_CONT+CAS_LATENCY+1) begin
		if (~wr & ram_req) ram_dout <= a[0] ? SDRAM_DQ[15:8] : SDRAM_DQ[7:0];
		else if (vram_req) vram_dout<=SDRAM_DQ;
		else if (~wr & tape_req) tape_dout <= a[0] ? SDRAM_DQ[15:8] : SDRAM_DQ[7:0];
		if (tape_req) tape_ack <= ~tape_ack;
	end
end

endmodule
