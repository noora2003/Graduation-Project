
`timescale 1ns / 1ps


module fixed_weight_top
#(
    parameter parameter_set = "hqc128",
 
  parameter N = (parameter_set == "hqc128") ? 17_669 : 
                  (parameter_set == "hqc192") ? 35_851 :
                  (parameter_set == "hqc256") ? 57_637 :
                                                17_669,
 
    parameter PARAM_N_HEX = (parameter_set == "hqc128") ? 15'h4505 :
                             (parameter_set == "hqc192") ? 16'h8c0b :
                             (parameter_set == "hqc256") ? 16'he125 :
                                                           15'h4505,
 
    parameter M = (parameter_set == "hqc128") ? 15 :
                  (parameter_set == "hqc192") ? 16 :
                  (parameter_set == "hqc256") ? 16 :
                                                15,
 
 
  //    parameter WEIGHT = (parameter_set == "hqc128")? 66:  //w=66 (KeyGen: x, y)
//                       (parameter_set == "hqc192")? 100:
//                       (parameter_set == "hqc256")? 131:
//                                                     66,
 
  parameter WEIGHT = (parameter_set == "hqc128") ? 75  :   //  w=75 (Encap: r1, r2, e)
                       (parameter_set == "hqc192") ? 114 :
                       (parameter_set == "hqc256") ? 149 :
                                                     75,
 
 
    parameter FILE_SKSEED = "",
 
    // common parameters
    parameter BITS_FROM_SHAKE = (32*WEIGHT) + (64 - (32*WEIGHT)%64)%64,
    parameter squeeze         = 32'h40000000 + BITS_FROM_SHAKE,
 
 
    parameter UTILS_REJECTION_THRESHOLD = (parameter_set == "hqc128") ? 24'hffdb89 :
                                          (parameter_set == "hqc192") ? 24'hff7811 :
                                          (parameter_set == "hqc256") ? 24'hffed0f :
                                                                        24'hffdb89,
 
    parameter LOG_WEIGHT = `CLOG2(WEIGHT),
    parameter E0_WIDTH   = 32,
    parameter E1_WIDTH   = 32,
    parameter SEED_SIZE  = 320,
 
    parameter k_WIDTH = (parameter_set == "hqc128") ? 18 :
                        (parameter_set == "hqc192") ? 17 :
                        (parameter_set == "hqc256") ? 17 :
                                                      18
)
  
  (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
 
//  input  logic        seed_valid,
    input  logic [31:0] sk_seed,
    input  logic [3:0]  sk_seed_addr,
    input  logic        sk_seed_wen,
 
    // request_another_vector = 11 - Request additional Fixed Weight from same seed with next context
    // request_another_vector = 01 - Reset Fixed Weight Vector Module to start with fresh context
    // request can be made only after the generation of the first vector
    // After generating first vector read out the generated vector before generating new one
 
    input  logic [1:0]              request_another_vector,
 
    output logic                    done,
    output logic                    valid_vector,
 
    output logic [M-1:0]            error_loc,
    input  logic                    rd_error_loc,
    input  logic [LOG_WEIGHT-1:0]   rd_addr_error_loc,
 
    // shake signals
    output logic        seed_valid_internal,
    input  logic        seed_ready_internal,
    output logic [31:0] din_shake,
    output logic        shake_out_capture_ready,
    input  logic [31:0] dout_shake_scrambled,
    output logic        force_done_shake,
    input  logic        dout_valid_sh_internal
);
  
// Internal signal declarations

    logic        init;
    logic        wr_en_ms;
    logic [LOG_WEIGHT:0] wr_addr_ms;
    logic [(M-1):0]      data_in_ms;
    logic                rd_en_ms;
    logic [(LOG_WEIGHT-1):0] rd_addr_ms;
    logic [(M-1):0]      data_out_ms;
    logic                collision_ms;
    logic        dout_valid_sh  = 1'b0;   
    logic        shift_shake_op = 1'b0;   
	logic        bml_not;    //not of beyond_max_limit             
    logic [31:0] dout_shake;
    logic [(M-1):0] shake_out_capture;
  
  // shake signals
	logic [1:0]  shake_input_type;
 
    logic        ready_onegen;
    logic        done_onegen;
    logic        start_onegen;
    logic [(M-1):0] location;
  
  // signals for seed loading
	logic [31:0] seed_in;
    logic [4:0]  seed_addr;
    logic        seed_wr_en;
    logic [31:0] seed_q;
    logic        initial_loading;
    logic [3:0]  addr_for_seed;
    logic        red_seed_valid = 1'b0;
    logic [31:0] squeeze_more;
  
  // Seed memory address mux
  
  assign addr_for_seed = (sk_seed_wen) ? sk_seed_addr : seed_addr[3:0];

  
// Seed memory instantiation
// ---------------------------------------------------------------------------
mem_single #(
    .WIDTH (32),
    .DEPTH (SEED_SIZE/32),
    .FILE  (FILE_SKSEED)
) mem_single_seed (
    .clock   (clk),
    .data    (sk_seed),
    .address (addr_for_seed),
    .wr_en   (sk_seed_wen),
    .q       (seed_q)
);
  
// ---------------------------------------------------------------------------
// SHAKE input mux
// ---------------------------------------------------------------------------
assign din_shake = (shake_input_type == 2'b01) ? squeeze        : // fblock / next seed
                   (shake_input_type == 2'b10) ? 32'h80000148   : // seed length 320+8 bits
                   (shake_input_type == 2'b11) ? 32'h00000002   : // Domain Separator
                                                  seed_q;  
  
assign dout_shake = dout_shake_scrambled;
  
// ---------------------------------------------------------------------------
// Barrett constants BRAM
// --------------------------------------------------------------------------- 
  
  parameter BARRETT_CONSTANTS = (parameter_set == "hqc128") ? "barrett_hqc_128.mem" :
                               (parameter_set == "hqc192") ? "barrett_hqc_192.mem" :
                               (parameter_set == "hqc256") ? "barrett_hqc_256.mem" :
                                                             "barrett_hqc_128.mem";
  
  logic [`CLOG2(WEIGHT)-1:0] addr_bc;
logic [k_WIDTH-1:0]        k_in;
  
mem_single #(
    .WIDTH (32),
    .DEPTH (WEIGHT),
    .FILE  (BARRETT_CONSTANTS)
) B_CONST (
    .clock   (clk),
    .data    (32'd0),
    .address (addr_bc),
    .wr_en   (1'b0),
    .q       (k_in)
);
  
// ---------------------------------------------------------------------------
// SHAKE output register + pipeline registers
// ---------------------------------------------------------------------------
logic        dout_valid_sh_internal_reg;
logic [31:0] dout_shake_reg;
 
always_ff @(posedge clk) begin
    dout_valid_sh_internal_reg <= dout_valid_sh_internal;
    dout_shake_reg             <= dout_shake;
//  n_minus_i_reg              <= n_minus_i;
end
  
// ---------------------------------------------------------------------------
// Barrett constant address counter
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (start || request_another_vector == 2'b11) begin
        addr_bc <= '0;
    end
    else if (dout_valid_sh_internal) begin
        addr_bc <= addr_bc + 1'b1;
    end
end
  
// ---------------------------------------------------------------------------
// n_minus_i counter (modulus for Barrett, decrements each iteration)
// ---------------------------------------------------------------------------
  logic [`CLOG2(N)-1:0] n_minus_i, n_minus_i_reg;
 
always_ff @(posedge clk) begin
    if (start) begin
        n_minus_i <= N;
    end
    else if (dout_valid_sh_internal_reg) begin
        n_minus_i <= n_minus_i - 1'b1;
    end
end
  
// ---------------------------------------------------------------------------
// Barrett reduction instance
// ---------------------------------------------------------------------------
logic                  dout_reduced_valid;
  logic [`CLOG2(N)-1:0] dout_shake_reduced;
 
barrett_red_gen #(
    .parameter_set (parameter_set)
) B_RED (
    .clk     (clk),
    .start   (dout_valid_sh_internal_reg),
    .done    (dout_reduced_valid),
    .a_in    (dout_shake_reg),
    .k_in    (k_in),
    .n_in    (n_minus_i),
    .red_out (dout_shake_reduced)
);  
  
 // ---------------------------------------------------------------------------
// Duplicate detection submodule signals
// ---------------------------------------------------------------------------
logic        init_mem_dd;
logic [(M-1):0]          location_dd;
logic [LOG_WEIGHT-1:0]   rd_addr_dd;
logic [LOG_WEIGHT-1:0]   wr_addr_dd;
logic                    wr_en_dd;
logic [(M-1):0]          wr_data_dd;
logic                    rd_en_dd;
logic                    start_dd;
logic                    collision_dd;
logic                    ready_dd;
logic                    done_dd;

logic [WIDTH-1:0] mem_out_0;  
assign location_dd = mem_out_0;
 
parameter MEM_WIDTH_DD = 128; 
// ---------------------------------------------------------------------------
// Duplicate detection instantiation
// ---------------------------------------------------------------------------
duplicate_detection #(
    .M        (M),
    .E0_WIDTH (MEM_WIDTH_DD),
    .E0_DEPTH (N/MEM_WIDTH_DD + 1),
    .WIDTH    (MEM_WIDTH_DD),
    .DEPTH    (N/MEM_WIDTH_DD + 1),
    .WEIGHT   (WEIGHT)
) DUP_DET (
    .clk      (clk),
    .rst      (rst),
    .init_mem (init_mem_dd),
    .location (location_dd),
    .start    (start_dd),
    .rd_addr  (rd_addr_dd),
    .rd_en    (rd_en_dd),
    .wr_data  (wr_data_dd),
    .wr_addr  (wr_addr_dd),
    .wr_en    (wr_en_dd),
    .ready    (ready_dd),
    // .valid  (valid),
    .collision (collision_dd),
    .done     (done_dd)
); 

// ---------------------------------------------------------------------------
// Location memory (pos[] working array) — dual-port BRAM
// ---------------------------------------------------------------------------
logic [31:0]             shake_output_counter;
 
  logic [`CLOG2(WEIGHT)-1:0] addr_0, addr_1;
  logic [`CLOG2(WEIGHT):0]   rd_addr;
// logic [`CLOG2(WEIGHT):0] wr_addr, rd_addr;
logic wr_en_0, wr_en_1;
  
assign addr_0 = rd_error_loc ? rd_addr_error_loc :
                rd_en_dd     ? rd_addr_dd         :
                               '0;
assign addr_1 = wr_en_dd? wr_addr_dd : rd_addr;
 
  logic [`CLOG2(N)-1:0] mem_in_0, mem_in_1;
  logic [`CLOG2(N)-1:0] mem_out_0, mem_out_1;
  logic [`CLOG2(N)-1:0] mem_comp;
  
assign mem_in_1 = wr_en_dd? wr_data_dd : addr_1 + dout_shake_reduced;
  
mem_dual #(
  .WIDTH ($CLOG2(N)),
    .DEPTH (WEIGHT),
    .FILE  ("test_input.inn")
) loca_mem (
    .clock     (clk),
    .data_0    (mem_in_0),
    .data_1    (mem_in_1),
    .address_0 (addr_0),
    .address_1 (addr_1),
    .wren_0    (wr_en_0),
    .wren_1    (wr_en_1),
//  .wren_1    (dout_reduced_valid),
    .q_0       (mem_out_0),
    .q_1       (mem_out_1)
);
  
assign error_loc = mem_out_0;
logic dout_shake_sel_red;
logic [LOG_WEIGHT-1:0] count;
  
// ---------------------------------------------------------------------------
// Main datapath FSM — state register
// ---------------------------------------------------------------------------
logic [4:0] state = 5'd0;
 
// state encoding 
parameter s_wait_for_shake  = 5'd0;
parameter s_init_mem        = 5'd1;
parameter s_load_shake      = 5'd2;
parameter s_stall           = 5'd3;
parameter s_swap            = 5'd4;
parameter s_wait_onegen     = 5'd5;
parameter s_stall_first     = 5'd6;
parameter s_done            = 5'd7;

// ---------------------------------------------------------------------------
// Main datapath FSM — sequential block
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (rst) begin
        // wr_addr           <=  '0;
        rd_addr              <= '0;
        done                 <= 1'b0;
        state                <= s_init_mem;
        force_done_shake     <= 1'b0;
        count                <= '0;
        // swap              <= 1'b0;
        // duplicate_detected <= 1'b0;
        shake_out_capture_ready <= 1'b0;
    end
    else begin
 
        if (state == s_init_mem) begin
            force_done_shake        <= 1'b0;
            count                   <= 2;
            // swap                 <= 1'b0;
            shake_out_capture_ready <= 1'b1;
            if (dout_reduced_valid) begin
                rd_addr <= rd_addr + 1'b1;
                // wr_addr <= wr_addr + 1;
                state   <= s_load_shake;
            end
            done <= 1'b0;
            // duplicate_detected <= 1'b0;
        end
 
        else if (state == s_load_shake) begin
            done <= 1'b0;
            // duplicate_detected <= 1'b0;
            force_done_shake <= 1'b0;
            // if (wr_addr > WEIGHT - 1) begin
            if (rd_addr > WEIGHT - 1) begin
                state <= s_stall;
                rd_addr <= WEIGHT - 1;
                shake_out_capture_ready <= 1'b0;
            end
            else begin
                shake_out_capture_ready <= 1'b1;
                if (dout_reduced_valid) begin
                    // wr_addr <= wr_addr + 1;
                    rd_addr <= rd_addr + 1'b1;
                    // swap    <= 1'b0;
                end
            end
        end
 
        else if (state == s_stall) begin
            if (ready_dd) begin
                state <= s_swap;
            end
        end
 
        else if (state == s_swap) begin
            if (done_dd) begin
                state <= s_done;
            end
        end
 
        else if (state == s_done) begin
            state <= s_init_mem;
            done  <= 1'b1;
            force_done_shake <= 1'b0;
            // swap                 <= 1'b0;
            // duplicate_detected   <= 1'b0;
            shake_out_capture_ready <= 1'b0;
            rd_addr                 <= '0;
            // wr_addr              <= '0;
        end
 
    end
end
  
// ---------------------------------------------------------------------------
// Main datapath FSM — combinational output block
// ---------------------------------------------------------------------------

  always_comb begin
    // defaults
    wr_en_0      = 1'b0;
    wr_en_1      = 1'b0;
    init_mem_dd  = 1'b0;
    start_dd     = 1'b0;
 
    case (state)
 
        s_init_mem: begin
            wr_en_0     = 1'b0;
            start_dd    = 1'b0;
            if (dout_reduced_valid) begin
                wr_en_1     = 1'b1;
                init_mem_dd = 1'b1;
            end
            else begin
                wr_en_1     = 1'b0;
                init_mem_dd = 1'b0;
            end
        end
 
        s_load_shake: begin
            wr_en_0     = 1'b0;
            init_mem_dd = 1'b0;
            start_dd    = 1'b0;
            if (dout_reduced_valid) begin
                wr_en_1 = 1'b1;
            end
            else begin
                wr_en_1 = 1'b0;
            end
        end
 
        s_stall: begin
            wr_en_0     = 1'b0;
            wr_en_1     = 1'b0;
            init_mem_dd = 1'b0;
            if (ready_dd) begin
                start_dd = 1'b1;
            end
            else begin
                start_dd = 1'b0;
            end
        end
 
        s_swap: begin
            wr_en_1     = wr_en_dd;
            wr_en_0     = 1'b0;
            init_mem_dd = 1'b0;
            start_dd    = 1'b0;
        end
 
        s_done: begin
            wr_en_1     = 1'b0;
            wr_en_0     = 1'b0;
            init_mem_dd = 1'b0;
            start_dd    = 1'b0;
        end
 
        default: begin
            wr_en_0     = 1'b0;
            wr_en_1     = 1'b0;
            init_mem_dd = 1'b0;
            start_dd    = 1'b0;
        end
 
    endcase
end
  
logic [31:0] count_reg = 32'd0;  // unused in original, preserved here
  
// SHAKE FSM — state register
  
logic [3:0] state_shake = 4'd0;
// state encoding 
parameter s_init_shake               = 4'd0;
parameter s_wait_for_shake_out_ready = 4'd1;
parameter s_shake_out_w              = 4'd2;
parameter s_shake_in_w               = 4'd3;
parameter s_load_new_seed            = 4'd4;
parameter s_stall_0                  = 4'd5;
parameter s_load_domain_sep          = 4'd6;
parameter s_wait                     = 4'd7;
parameter s_wait_for_collision_2     = 4'd8;
parameter s_wait_for_collision_3     = 4'd9;
parameter s_wait_for_collision_4     = 4'd10;
 
logic [1:0] count_steps;
logic       seed_is_loaded_in_shake;
logic       shake_result_ready;
logic       seed_is_loaded_in_shake_off;

// shake parallel processing / seed loading
  
always_ff @(posedge clk) begin
 
    // ============== start feeding the SHAKE with seed ====================
    if (rst) begin
        state_shake             <= s_init_shake;
        seed_addr               <= '0;
        seed_is_loaded_in_shake <= 1'b0;
        shake_result_ready      <= 1'b0;
    end
    else begin
 
        if (state_shake == s_init_shake) begin
            count_steps  <= 2'd0;
            seed_addr    <= '0;
            seed_is_loaded_in_shake <= 1'b0;
            if (start) begin
                state_shake  <= s_shake_out_w;
                shake_result_ready <= 1'b0;
            end
        end
 
        else if (state_shake == s_shake_out_w) begin
            if (request_another_vector == 2'b01) begin
                state_shake <= s_init_shake;
                seed_is_loaded_in_shake <= 1'b0;
            end
            else begin
                if (count_steps == 2'd1) begin
                    state_shake <= s_shake_in_w;
                    count_steps <= 2'd0;
                end
                else begin
                    state_shake <= s_shake_out_w;
                    count_steps <= count_steps + 1'b1;
                end
            end
        end
 
        else if (state_shake == s_shake_in_w) begin
            if (request_another_vector == 2'b01) begin
                state_shake   <= s_init_shake;
                seed_is_loaded_in_shake <= 1'b0;
            end
            else begin
                if (count_steps == 2'd1) begin
                    state_shake <= s_load_new_seed;
                    count_steps <= 2'd0;
                end
                else begin
                    state_shake <= s_shake_in_w;
                    count_steps <= count_steps + 1'b1;
                end
            end
        end
 
        else if (state_shake == s_load_new_seed) begin
            if (request_another_vector == 2'b01) begin
                state_shake  <= s_init_shake;
                seed_is_loaded_in_shake <= 1'b0;
            end
            else begin
                if (seed_addr == SEED_SIZE/32) begin
                    seed_addr   <= '0;
                    seed_is_loaded_in_shake <= 1'b1;
//                  state_shake             <= s_init_shake;
                    state_shake  <= s_wait;
                end
                else begin
                    state_shake <= s_stall_0;
                    seed_addr   <= seed_addr + 1'b1;
                end
            end
        end
 
        else if (state_shake == s_stall_0) begin
            if (request_another_vector == 2'b01) begin
                state_shake   <= s_init_shake;
                seed_is_loaded_in_shake <= 1'b0;
            end
//          else if (request_another_vector == 2'b11) begin
//              state_shake <= s_load_domain_sep;
//          end
            else begin
                state_shake <= s_load_new_seed;
            end
        end
 
        else if (state_shake == s_wait) begin
            if (request_another_vector == 2'b01) begin
                state_shake  <= s_init_shake;
                seed_is_loaded_in_shake <= 1'b0;
            end
            else if (request_another_vector == 2'b11) begin
                state_shake <= s_load_domain_sep;
            end
        end
 
        else if (state_shake == s_load_domain_sep) begin
            if (request_another_vector == 2'b01) begin
                state_shake <= s_init_shake;
                seed_is_loaded_in_shake <= 1'b1;
            end
            else begin
                state_shake <= s_wait;
            end
        end
 
    // ============== end feeding the SHAKE with seed ======================
    end
end
 
// SHAKE FSM — combinational output block
  
always_comb begin
    // defaults
    seed_valid_internal = 1'b0;
    shake_input_type    = 2'b00;
 
    case (state_shake)
 
        s_init_shake: begin
            seed_valid_internal = 1'b0;
            shake_input_type    = 2'b00;
        end
 
        s_shake_out_w: begin
            if (count_steps == 2'd0) begin
                shake_input_type    = 2'b01;
                seed_valid_internal = 1'b1;
            end
            else begin
                seed_valid_internal = 1'b0;
            end
        end
 
        s_shake_in_w: begin
            if (count_steps == 2'd0) begin
                shake_input_type    = 2'b10;
                seed_valid_internal = 1'b1;
            end
            else begin
                seed_valid_internal = 1'b0;
            end
        end
 
        s_load_new_seed: begin
            if (seed_addr < SEED_SIZE/32) begin
                seed_valid_internal = 1'b1;
                shake_input_type    = 2'b00;
            end
            else begin
                seed_valid_internal = 1'b1;
                shake_input_type    = 2'b11;
            end
        end
 
        s_wait: begin
            seed_valid_internal = 1'b0;
        end
 
        s_load_domain_sep: begin
            shake_input_type    = 2'b01;
            seed_valid_internal = 1'b1;
        end
 
        default: seed_valid_internal = 1'b0;
 
    endcase
end
 
endmodule
