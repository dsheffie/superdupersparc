`ifndef __fp_nan_hdr__
`define __fp_nan_hdr__

/* SPARC V8 NaN semantics (IEEE 754): a NaN is SIGNALING when its quiet bit (the
 * fraction MSB) is CLEAR.  An op with a NaN operand returns one of them, quieted:
 * an sNaN in rs2 (b), else an sNaN in rs1 (a), else a qNaN in rs2, else rs1
 * (interpret.cc pick_nan32/64).  An invalid op on non-NaN operands returns the
 * default NaN, 0x7fffffff / 0x7fffffffffffffff.  fmt: 0 = single (low 32 bits),
 * 1 = double.  (r9999's R4400 used the legacy inverse rule and a default NaN.) */

localparam [63:0] SPARC_DNAN_D = 64'h7fffffffffffffff;
localparam [63:0] SPARC_DNAN_S = 64'h000000007fffffff;

function automatic logic fp_is_nan(input logic [63:0] x, input logic fmt);
   begin
      fp_is_nan = fmt ? ((&x[62:52]) & (|x[51:0])) : ((&x[30:23]) & (|x[22:0]));
   end
endfunction // fp_is_nan

function automatic logic fp_is_snan(input logic [63:0] x, input logic fmt);
   begin
      fp_is_snan = fp_is_nan(x, fmt) & !(fmt ? x[51] : x[22]);
   end
endfunction // fp_is_snan

function automatic logic [63:0] fp_quiet(input logic [63:0] x, input logic fmt);
   begin
      fp_quiet = fmt ? (x | 64'h0008000000000000) : {32'd0, x[31:0] | 32'h00400000};
   end
endfunction // fp_quiet

/* the result of an op with a NaN operand (either a or b is a NaN) */
function automatic logic [63:0] sparc_nan(input logic [63:0] a, input logic [63:0] b, input logic fmt);
   begin
      sparc_nan = fp_is_snan(b, fmt) ? fp_quiet(b, fmt) :
		  fp_is_snan(a, fmt) ? fp_quiet(a, fmt) :
		  fp_is_nan(b, fmt) ? fp_quiet(b, fmt) : fp_quiet(a, fmt);
   end
endfunction // sparc_nan

`endif
