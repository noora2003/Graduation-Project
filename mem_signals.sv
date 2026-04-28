module mem_single
  #(
    parameter WIDTH = 8,
    parameter DEPTH = 64,
    parameter FILE = "",
    parameter INIT = 0
  )
  (
  input  logic                      clock,
  input  logic [WIDTH-1:0]          data,
    input  logic [$clog2(DEPTH)-1:0]  address,
  input  logic                      wr_en,
  output logic [WIDTH-1:0]          q
);
  
// Memory array
// Synthesis attributes:
//   Vivado  : ram_style = "block"   infer BRAM
//   Quartus : ramstyle  = "M20K"    infer M20K BRAM
// ---------------------------------------------------------------------------
(* ram_style = "block" *) logic [WIDTH-1:0] mem [DEPTH-1:0] /* synthesis ramstyle = "M20K" */;
  
  initial begin
    // Load from hex file if FILE parameter is provided
    if (FILE != "") begin
        $readmemb(FILE, mem);   
    end
    if (INIT) begin
        for (int i = 0; i < DEPTH; i = i + 1) begin  
            mem[i] = {WIDTH{1'b0}};
        end
    end
end
  
always_ff @(posedge clock) begin
    if (wr_en) begin
        mem[address] <= data;
      //q <= data;
        
    end
    else begin
        q <= mem[address];
    end
end
 
endmodule
