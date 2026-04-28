`timescale 1ns / 1ps
/*
 * barrett_red_gen.sv
 *
 * Barrett Reduction for HQC Fixed-Weight Vector Generator
 * =========================================================================
 *
 * PURPOSE:
 *   In the CWW Fisher-Yates algorithm, each iteration i needs a random
 *   index s in range [i, n-1]. The hardware draws a raw 32-bit word from
 *   SHAKE256 and must compute:
 *
 *       raw mod (n - i)
 *
 *   The modulus (n-i) changes every iteration. A hardware divider is too
 *   large and too slow. A rejection loop is not constant-time.
 *   Barrett reduction solves both problems:
 *     - Replaces division with multiplications and shifts
 *     - Always takes the same number of cycles (constant-time)
 *     - Maps efficiently to DSP48 blocks on Artix-7
 *
 * BARRETT ALGORITHM:
 *   Given:
 *     x   = raw SHAKE256 word (32-bit input)
 *     m   = n - i            (current modulus, M bits wide)
 *     k   = precomputed Barrett constant = floor(2^(M + 32) / m)
 *           stored in B_CONST BRAM, one entry per iteration
 *
 *   Steps:
 *     1. q = floor((x * k) >> (M + 32))    [upper bits of product]
 *     2. r = x - q * m                      [remainder estimate]
 *     3. if r >= m: r = r - m               [at most one correction]
 *                                            [constant-time via mux]
 *
 *   Result: r = x mod m, always in [0, m-1]
 *
 * PIPELINE STRUCTURE (3 stages, fully registered):
 *
 *   Cycle 1 (STAGE_MULT1): Compute x * k  → product_xk (wide multiply)
 *   Cycle 2 (STAGE_SHIFT): Extract upper bits → q = product_xk >> (M+32)
 *                          Compute q * m      → product_qm
 *   Cycle 3 (STAGE_SUB):   r = x - q*m
 *                          Correction: if r >= m → r = r - m  (mux, CT)
 *                          Assert done, output red_out
 
 * =========================================================================
 */

module barrett_red_gen
#(
    parameter parameter_set = "hqc128",

    // n: vector length
    parameter N = (parameter_set == "hqc128") ? 17_669 :
                  (parameter_set == "hqc192") ? 35_851 :
                  (parameter_set == "hqc256") ? 57_637 :
                                                17_669,

    // M: number of bits to represent N
    parameter M = (parameter_set == "hqc128") ? 15 :
                  (parameter_set == "hqc192") ? 16 :
                  (parameter_set == "hqc256") ? 16 :
                                                15,

    // k_WIDTH: width of Barrett constant k = floor(2^(M+32) / m)
    // For HQC-128: k fits in 18 bits (M=15, modulus ~17669, k ~ 2^47/17669 ~ 2^17)
    // For HQC-192/256: k fits in 17 bits
    parameter k_WIDTH = (parameter_set == "hqc128") ? 18 :
                        (parameter_set == "hqc192") ? 17 :
                        (parameter_set == "hqc256") ? 17 :
                                                      18,

    // Internal width constants
    // product_xk width: 32 + k_WIDTH bits
    // product_qm width: M + M bits (q is at most M bits, m is M bits)
    parameter XK_WIDTH = 32 + k_WIDTH,          // width of x*k product
    parameter QM_WIDTH = 2 * M                  // width of q*m product
)
(
    input  logic              clk,
    input  logic              start,       // pulse: begin reduction
    output logic              done,        // pulse: result ready on red_out
    input  logic [31:0]       a_in,        // raw SHAKE256 word (x)
    input  logic [k_WIDTH-1:0] k_in,      // Barrett constant from B_CONST BRAM
    input  logic [M-1:0]      n_in,        // current modulus (n - i)
    output logic [M-1:0]      red_out      // result: a_in mod n_in
);

// =========================================================================
// Pipeline stage registers
// =========================================================================

// --------------------------------------------------------------------------
// STAGE 1 → STAGE 2 pipeline registers
// Registered at end of cycle 1 (after x*k multiply)
// --------------------------------------------------------------------------
logic                   stage2_valid;     // start delayed by 1 cycle
logic [XK_WIDTH-1:0]    product_xk;       // x * k  (wide)
logic [M-1:0]           n_reg1;           // n_in registered for use in stage 2
logic [31:0]            a_reg1;           // a_in registered for use in stage 3

// --------------------------------------------------------------------------
// STAGE 2 → STAGE 3 pipeline registers
// Registered at end of cycle 2 (after q extraction and q*m multiply)
// --------------------------------------------------------------------------
logic                   stage3_valid;     // start delayed by 2 cycles
logic [M-1:0]           q_reg;            // quotient estimate q
logic [QM_WIDTH-1:0]    product_qm;       // q * m
logic [M-1:0]           n_reg2;           // n_in registered for use in stage 3
logic [31:0]            a_reg2;           // a_in registered for use in stage 3

// =========================================================================
// STAGE 1: Compute x * k
// =========================================================================
// x = a_in (32-bit raw SHAKE word)
// k = k_in (Barrett constant from BRAM, k_WIDTH bits)
// product_xk = x * k  (XK_WIDTH = 32 + k_WIDTH bits)
//
// Hardware: maps to DSP48E1 on Artix-7
//   For HQC-128: 32 × 18 = 50-bit product → 1 DSP48
//   Output registered at end of cycle 1
// =========================================================================
always_ff @(posedge clk) begin
    stage2_valid <= start;

    if (start) begin
        // Wide multiply: x * k
        // Using unsigned multiplication — both operands are positive integers
        product_xk <= ({{(k_WIDTH){1'b0}}, a_in}) *
                      ({32'b0, k_in});
        // Pipeline: register n and a for later stages
        n_reg1     <= n_in;
        a_reg1     <= a_in;
    end
    else begin
        product_xk <= '0;
        n_reg1     <= '0;
        a_reg1     <= '0;
    end
end

// =========================================================================
// STAGE 2: Extract q and compute q * m
// =========================================================================
// q = floor(x * k / 2^(M + 32))
//   = upper bits of product_xk, specifically bits [XK_WIDTH-1 : M+32]
//   Wait — for Barrett: shift amount = M + 32 bits from the bottom
//   So q = product_xk >> (M + 32)
//   Since XK_WIDTH = 32 + k_WIDTH, and k was chosen so q fits in M bits:
//   q = product_xk[XK_WIDTH-1 : 32+M] ... but actually for the standard
//   Barrett with k = floor(2^(M+32)/m):
//     q = (x * k) >> (M + 32)
//   The shift discards the lower (M+32) bits.
//   For HQC-128: M=15, shift = 47 bits
//     q = product_xk[XK_WIDTH-1 : 47]
//
// Then compute q * m (m = n_reg1 = current modulus)
// =========================================================================
logic [M-1:0] q_internal;

always_comb begin
    // Extract q by right-shifting product_xk by (M + 32) positions
    // q fits in at most k_WIDTH - M bits (which is small, ≤ M bits)
    q_internal = product_xk[XK_WIDTH-1 : M+32];
end

always_ff @(posedge clk) begin
    stage3_valid <= stage2_valid;

    if (stage2_valid) begin
        q_reg      <= q_internal;
        // q * m: quotient estimate × modulus
        // Both operands are M bits wide → product is 2M bits
		product_qm <= ({{M{1'b0}}, q_internal}) * ({{M{1'b0}}, n_reg1});
        n_reg2     <= n_reg1;
        a_reg2     <= a_reg1;
    end
    else begin
        q_reg      <= '0;
        product_qm <= '0;
        n_reg2     <= '0;
        a_reg2     <= '0;
    end
end

// =========================================================================
// STAGE 3: Compute remainder and correction
// =========================================================================
// r = x - q*m
//   Note: x is 32-bit, q*m is at most 32-bit for valid HQC parameters
//   (since q < x/m + 1 < N/1 + 1, and m < N < 2^M ≤ 2^16)
//
// Correction (constant-time):
//   Barrett guarantees r is in [0, 2m).
//   If r >= m: r_final = r - m
//   If r <  m: r_final = r
//   Implemented as a mux — NOT a branch — constant-time guaranteed.
//
// Output:
//   red_out = r_final = a_in mod n_in  (M bits, in [0, n_in-1])
//   done    = stage3_valid (pulsed for 1 cycle)
// =========================================================================
logic [31:0]  r_raw;      // x - q*m (may be slightly > m, at most 2m-1)
logic [M-1:0] r_corrected;// after one correction step

always_comb begin
    // r = x - q*m
    // a_reg2 is 32-bit, product_qm lower 32 bits are sufficient
    // (upper bits of product_qm are zero for valid Barrett parameters)
    r_raw = a_reg2 - product_qm[31:0];

    // Constant-time correction:
    // If r_raw >= n_reg2 → subtract n_reg2 once
    // Use mux: r_corrected = (r_raw >= n_reg2) ? r_raw - n_reg2 : r_raw
    // Both branches always computed, mux selects — same timing either way
    if (r_raw >= {16'b0, n_reg2}) begin
        r_corrected = r_raw[M-1:0] - n_reg2;
    end
    else begin
        r_corrected = r_raw[M-1:0];
    end
end

always_ff @(posedge clk) begin
    done    <= stage3_valid;
    if (stage3_valid) begin
        red_out <= r_corrected;
    end
    else begin
        red_out <= '0;
    end
end

endmodule
