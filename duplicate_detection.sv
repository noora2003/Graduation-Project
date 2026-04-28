// Code your design here
`timescale 1ns / 1ps


module duplicate_detection
    #(
    parameter M          = 15,

    parameter E0_WIDTH   = 32,
    parameter E0_DEPTH   = 17696/32,
    parameter LOGE0W     = `clog2(E0_DEPTH),
    parameter E0_FILE    = "",

    parameter WIDTH      = 32,
    parameter DEPTH      = 17696/32,
    parameter LOGW       = `clog2(DEPTH),
    parameter FILE       = "",

    parameter WEIGHT     = 75,
    parameter LOG_WEIGHT = `clog2(WEIGHT)
    )
    (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    init_mem,
    input  logic [(M-1):0]          location,

    output logic [LOG_WEIGHT-1:0]   rd_addr,
    output logic [LOG_WEIGHT-1:0]   wr_addr,
    output logic                    wr_en,
    output logic [(M-1):0]          wr_data,

    output logic                    rd_en,
    input  logic                    start,
    output logic                    collision,
    output logic                    ready,
    output logic                    valid,
    output logic                    done
    );

// ---------------------------------------------------------------------------
// Internal signal declarations
// ---------------------------------------------------------------------------
logic [WIDTH-1:0]      gen_one;

// logic [WIDTH-1:0]   gen_one_reg_rev;
logic [WIDTH-1:0]      gen_one_reg;       
logic [WIDTH-1:0]      data_0, data_1;
logic [LOGW-1:0]       addr_0, addr_1;
logic [LOGW-1:0]       decode_addr;
logic [LOGW-1:0]       addr_1_mux;
logic [LOGW-1:0]       addr_read;
logic [WIDTH-1:0]      q_0, q_1;
logic                  wren_0, wren_1;

logic [LOG_WEIGHT-1:0] rd_addr_reg;

logic                  ready_s;
logic                  valid_s;
logic                  done_s;
logic                  init;
logic                  reading_out;
logic                  collision_s;

logic [WIDTH-1:0]      error_1;

// ---------------------------------------------------------------------------
// State encoding (same values as original)
// ---------------------------------------------------------------------------
parameter s_wait_for_init_mem = 4'd0;
parameter s_initialize        = 4'd1;
parameter s_init_done         = 4'd2;
parameter s_wait_start        = 4'd3;
parameter s_load_loc          = 4'd4;
parameter s_wait_last_2       = 4'd5;
parameter s_read_out          = 4'd6;
parameter s_done              = 4'd7;
parameter s_stall_for_ram     = 4'd8;
//parameter s_stall_for_ram_2   = 4'd9;   
logic [3:0]          state     = 4'd0;
logic [LOG_WEIGHT:0] count_reg;

// ---------------------------------------------------------------------------
// Output assignmentsk
// ---------------------------------------------------------------------------
assign ready   = ready_s;
assign valid   = valid_s;
assign done    = done_s;
assign wr_en   = collision_s;
assign wr_data = {{(M-LOG_WEIGHT){1'b0}}, wr_addr};

// ---------------------------------------------------------------------------
// gen_one: 1-hot word — bit i is set when i == (location % WIDTH)
// Maps incoming index to its correct bit lane within a WIDTH-bit BRAM word
// ---------------------------------------------------------------------------
genvar i;
generate
    for (i = 0; i < WIDTH; i=i+1) begin : vector_gen
        assign gen_one[i] = (i == location % WIDTH) ? 1'b1 : 1'b0;
    end
endgenerate


always_ff @(posedge clk) begin
    gen_one_reg <= gen_one;   
end

// ---------------------------------------------------------------------------
// data_0: all zeros — clears BRAM words during init phase
// decode_addr: BRAM word address = location / WIDTH
// ---------------------------------------------------------------------------
assign data_0      = '0;
assign decode_addr = location / WIDTH;

// ---------------------------------------------------------------------------
//
// Collision logic:
//   If q_0 == data_1 after the OR, the bit was already 1 → duplicate index
//   If q_0 != data_1, the bit was 0 → index is new → no collision
//
// ---------------------------------------------------------------------------
assign data_1 = (q_0 | gen_one);   


always_ff @(posedge clk) begin
//  if (init|start) begin
//      collision_s <= 1'b0;
//  end
//  else if (wren_1) begin
    if (wren_1) begin
        if (q_0 == data_1) begin
            collision_s <= 1'b1;   
        end
    end
    else begin
        collision_s <= 1'b0;       
    end
end

assign collision = collision_s;

assign error_1 = q_1;

// ---------------------------------------------------------------------------
// Dual-port BRAM — occupancy bitmap
// Port 0 (read):  checks if index already present
// Port 1 (write): sets the bit for newly accepted index
// ---------------------------------------------------------------------------
mem_dual #(
    .WIDTH (WIDTH),
    .DEPTH (DEPTH),
    .FILE  (FILE)
) mem_dual_A (
    .clock     (clk),
    .data_0    (data_0),
    .data_1    (data_1),
    .address_0 (addr_read),
    .address_1 (addr_1_mux),
    .wren_0    (wren_0),
    .wren_1    (wren_1),
    .q_0       (q_0),
    .q_1       (q_1)
);

assign addr_read  = reading_out ? addr_0 : decode_addr;
assign addr_1_mux = addr_1;

// ---------------------------------------------------------------------------
// Main FSM — sequential block
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (rst) begin
        state     <= s_wait_for_init_mem;
        addr_0    <= '0;
        count_reg <= '0;
        addr_1    <= '0;
        ready_s   <= 1'b0;
    end
    else begin

        if (state == s_wait_for_init_mem) begin
            done_s    <= 1'b0;
           
            valid_s   <= 1'b0;
            addr_1    <= '0;
            addr_0    <= '0;
            rd_addr   <= '0;
            count_reg <= '0;
            ready_s   <= 1'b0;

            if (init_mem) begin
                state <= s_initialize;
            end
        end

        else if (state == s_initialize) begin
            valid_s   <= 1'b0;
            done_s    <= 1'b0;
            addr_1    <= '0;
            addr_0    <= '0;
            rd_addr   <= '0;
            count_reg <= '0;
            state     <= s_init_done;
            ready_s   <= 1'b0;
        end

        else if (state == s_init_done) begin
            if (addr_0 == DEPTH - 1) begin
                addr_0  <= '0;
                state   <= s_wait_start;
                ready_s <= 1'b1;
            end
            else begin
                addr_0 <= addr_0 + 1'b1;
                state  <= s_init_done;
            end
        end

        else if (state == s_wait_start) begin
            if (start) begin
                ready_s <= 1'b0;
//              if (rd_addr == WEIGHT-1) begin
//                  state <= s_wait_last_2;
//              end
//              else begin
                state   <= s_load_loc;
                rd_addr <= WEIGHT - 1;
//              end
            end
        end

        else if (state == s_load_loc) begin
//          if (~collision_s) begin
//              if (rd_addr == WEIGHT-1) begin
            if (rd_addr == 0) begin
                state     <= s_wait_last_2;
                addr_1    <= decode_addr;
                count_reg <= count_reg + 1'b1;
            end
            else begin
                state     <= s_stall_for_ram;
                rd_addr   <= rd_addr - 1'b1;
                addr_0    <= decode_addr;
                addr_1    <= decode_addr;
                count_reg <= count_reg + 1'b1;
            end
//          end
//          else begin
//              state     <= s_wait_start;
//              rd_addr   <= rd_addr - 1;
//              count_reg <= count_reg - 1;
//              ready_s   <= 1'b1;
//          end
        end

        else if (state == s_stall_for_ram) begin
//          if (~collision_s) begin
            state <= s_load_loc;
//          end
//          else begin
//              state     <= s_wait_start;
//              rd_addr   <= rd_addr - 1;
//              count_reg <= count_reg - 1;
//              ready_s   <= 1'b1;
//          end
        end

//         else if (state == s_wait_last_2) begin
//             if (~collision_s) begin
//                 if (count_reg == WEIGHT+2-1) begin
//                     count_reg <= '0;
//                     state     <= s_done;
//                     addr_0    <= '0;
//                 end
//                 else begin
//                     state     <= s_wait_last_2;
//                     count_reg <= count_reg + 1'b1;
//                     addr_1    <= decode_addr;
//                 end
//             end
//             else begin
//                 state     <= s_wait_start;   
//                 count_reg <= count_reg - 1'b1;
//                 ready_s   <= 1'b1;
//             end
//         end
      // Instead of branching back to s_wait_start on collision:
          else if (state == s_wait_last_2) begin
              // Always continue — never exit early
              if (count_reg == WEIGHT+2-1) begin
                  state <= s_done;              // always exit after fixed count
              end
              else begin
                  state     <= s_wait_last_2;
                  count_reg <= count_reg + 1'b1;
                  addr_1    <= decode_addr;
              end
              // collision_s is still detected and reported
              // but it does NOT change the number of cycles
          end

        else if (state == s_read_out) begin
            valid_s <= 1'b1;
            if (addr_0 == DEPTH-1) begin
                state  <= s_done;
                addr_0 <= '0;
            end
            else begin
                state  <= s_read_out;
                addr_0 <= addr_0 + 1'b1;
            end
        end

        else if (state == s_done) begin
            done_s  <= 1'b1;
            valid_s <= 1'b0;
            state   <= s_wait_for_init_mem;
        end

    end

    // rd_addr pipeline — outside if/else block, runs every clock (same as original)
    rd_addr_reg <= rd_addr;
    wr_addr     <= rd_addr_reg;
end

// ---------------------------------------------------------------------------
// Combinational output block
// ---------------------------------------------------------------------------
always_comb begin
    // defaults
    wren_0      = 1'b0;
    wren_1      = 1'b0;
    init        = 1'b0;
    rd_en       = 1'b0;
    reading_out = 1'b0;

    case (state)

        s_initialize: begin
            wren_0      = 1'b1;
            wren_1      = 1'b0;
            init        = 1'b1;
            rd_en       = 1'b0;
            reading_out = 1'b1;
        end

        s_init_done: begin
            wren_0 = 1'b1;
            wren_1 = 1'b0;
            init   = 1'b0;
        end

        s_wait_start: begin
            wren_0      = 1'b0;
            wren_1      = 1'b0;
            reading_out = 1'b0;
            rd_en       = start ? 1'b1 : 1'b0;
        end

        s_load_loc: begin
            rd_en  = 1'b1;
            wren_1 = 1'b0;
        end

        s_stall_for_ram: begin
            wren_1 = 1'b1;
        end

        s_wait_last_2: begin
            rd_en  = 1'b0;
            wren_1 = (count_reg < WEIGHT+1) ? 1'b1 : 1'b0;
        end

        s_read_out: begin
            wren_1      = 1'b0;
            reading_out = 1'b1;
        end

        s_done: begin
            wren_0      = 1'b0;
            wren_1      = 1'b0;
            reading_out = 1'b0;
        end

        default: begin
            wren_0      = 1'b0;
            wren_1      = 1'b0;
            init        = 1'b0;
            rd_en       = 1'b0;
            reading_out = 1'b0;
        end

    endcase
end

endmodule
