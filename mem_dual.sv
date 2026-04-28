module mem_dual
#(
  parameter WIDTH = 8,
  parameter DEPTH = 64,
  parameter FILE = "",
  parameter INIT = 0
)
  (
    // port 0 and port 1
  input  logic                      clock,
  input  logic [WIDTH-1:0]          data_0,
  input  logic [WIDTH-1:0]          data_1,
    input  logic [$clog2(DEPTH)-1:0]  address_0,
    input  logic [$clog2(DEPTH)-1:0]  address_1,
  input  logic                      wren_0,
  input  logic                      wren_1,
  output logic [WIDTH-1:0]          q_0,
  output logic [WIDTH-1:0]          q_1
);
  //tells FPGA tools to use Block RAM (BRAM) instead of registers
  
(* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1] /* synthesis ramstyle = "M20K" */;
  
initial begin
    if (FILE != "") begin
        $readmemb(FILE, mem);   
    end
 
    // Zero-initialise all entries if INIT is set
    // NOTE: overwrites file contents if both FILE and INIT are set
    if (INIT) begin
        for (int i = 0; i < DEPTH; i = i + 1) begin  // FIX 3: int i scoped locally
            mem[i] = {WIDTH{1'b0}};
        end 
      
      
  always_ff @(posedge clock) begin
    if (wren_0) begin
        mem[address_0] <= data_0;
      //  q_0 <= data_0 (write-first → no-change)(fixed)
    end
    else begin
        q_0 <= mem[address_0];
    end
end
      
always_ff @(posedge clock) begin
    if (wren_1) begin
        mem[address_1] <= data_1;
      //  q_1 <= data_1 (write-first → no-change) (fixed)
    end
    else begin
        q_1 <= mem[address_1];
    end
end
 
endmodule
