/* reg_ram1rw with separate read and write addresses: the same timing (the address,
 * write data and enable are registered, so a read returns two cycles after its
 * address and a write lands a cycle after it is presented; a read and a write of one
 * address in the same cycle return the old data).  With rd_addr == wr_addr it is
 * reg_ram1rw.  The L2's hit pipeline (l2.sv, L2_PIPE) reads for a new request while
 * an older one writes. */
module reg_ram1r1w(clk, rd_addr, wr_addr, wr_data, wr_en, rd_data);
   input logic clk;
   parameter WIDTH = 1;
   parameter LG_DEPTH = 1;
   input logic [LG_DEPTH-1:0] rd_addr;
   input logic [LG_DEPTH-1:0] wr_addr;
   input logic [WIDTH-1:0]    wr_data;
   input logic 		      wr_en;
   output logic [WIDTH-1:0]   rd_data;

   localparam DEPTH = 1<<LG_DEPTH;
   logic [WIDTH-1:0] 	      r_ram[DEPTH-1:0];

   logic [LG_DEPTH-1:0]       r_rd_addr;
   logic [LG_DEPTH-1:0]       r_wr_addr;
   logic 		      r_wr_en;
   logic [WIDTH-1:0] 	      r_wr_data;

   always_ff@(posedge clk)
     begin
	r_rd_addr <= rd_addr;
	r_wr_addr <= wr_addr;
	r_wr_en <= wr_en;
	r_wr_data <= wr_data;

	rd_data <= r_ram[r_rd_addr];
	if(r_wr_en)
	  begin
	     r_ram[r_wr_addr] <= r_wr_data;
	  end
     end // always_ff@ (posedge clk)

endmodule // reg_ram1r1w
