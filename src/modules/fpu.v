`timescale 1ns/1ps
module fpu(
    input wire clk,
    input wire rst,
    input wire start,
    input wire [3:0] op,    // 0=fadd, 1=fsub, 2=floor, 3=ceil, 4=round, 5=fmul, 6=fdiv, 7=fmin, 8=fmax, 9=feq, 10=flt, 11=fle
    input wire [31:0] a,
    input wire [31:0] b,
    input wire [2:0] rm,    // rounding mode
    output reg [31:0] out,
    output reg ready,
    output reg [4:0] fflags // nv, dz, of, uf, nx
);

    // -------------------------------------------------------------------------
    // Simple Multi-Cycle FPU (Best for Cycle Time & Easy to Read)
    // -------------------------------------------------------------------------
    
    localparam IDLE           = 3'd0;
    localparam ALIGN_MUL_DIV  = 3'd1;
    localparam ADD            = 3'd2;
    localparam NORM           = 3'd3;
    localparam DIVIDE_LOOP    = 3'd4;

    reg [2:0] state;
    reg sign_a, sign_b, sign_res;
    reg [8:0] exp_a, exp_b;
    reg signed [9:0] exp_res; // Extra bits for overflow/underflow checks
    reg [24:0] mant_a, mant_b, mant_res;
    
    reg [47:0] div_P; // For multi-cycle division
    reg [47:0] div_A;
    reg [5:0] div_count;
    
    // Combinational helpers for single-cycle operations
    wire [8:0] exp_diff_ab = exp_a - exp_b;
    wire [8:0] exp_diff_ba = exp_b - exp_a;
    reg [4:0] shift_amt;
    reg [24:0] shifted_mant;

    // Rounding specific combinational logic
    function [31:0] compute_round;
        input [31:0] a;
        input [3:0] op;
        reg r_sign;
        reg [7:0] r_exp;
        reg [22:0] r_mant;
        reg [4:0] mask_shift;
        reg [23:0] frac_mask;
        reg [23:0] mant_mask;
        reg [23:0] full_mant;
        reg [23:0] m_int;
        reg [23:0] m_frac;
        reg round_up;
        reg [23:0] half;
        reg [24:0] m_added;
        begin
            r_sign = a[31];
            r_exp = a[30:23];
            r_mant = a[22:0];
            compute_round = a; // default to identity
            
            if (r_exp == 8'hFF) begin // NaN or Inf
                if (r_mant != 0) begin
                    compute_round = {r_sign, 8'hFF, 1'b1, 22'b0}; // Canonicalize Quiet NaN payload
                end else begin
                    compute_round = a; // +/- Infinity stays unmodified
                end
            end else if (r_exp < 8'd127) begin
                // Absolute value < 1.0
                if (op == 4'd2) begin // FLOOR
                    if (r_exp == 0 && r_mant == 0) begin
                        compute_round = {r_sign, 31'b0}; // +/- 0.0
                    end else begin
                        compute_round = r_sign ? 32'hBF800000 : {r_sign, 31'b0}; // -1.0 or +/-0.0
                    end
                end else if (op == 4'd3) begin // CEIL
                    if (r_exp == 0 && r_mant == 0) begin
                        compute_round = {r_sign, 31'b0}; // +/- 0.0
                    end else begin
                        compute_round = r_sign ? {r_sign, 31'b0} : 32'h3F800000; // +/-0.0 or 1.0
                    end
                end else if (op == 4'd4) begin // ROUND
                    if (r_exp == 8'd126 && r_mant != 0) begin
                        // > 0.5 -> 1.0
                        compute_round = {r_sign, 8'd127, 23'd0}; // +/- 1.0
                    end else if (r_exp == 8'd126 && r_mant == 0) begin
                        // == 0.5 -> 0.0 (tie to even, 0 is even)
                        compute_round = {r_sign, 31'b0};
                    end else begin
                        // < 0.5 -> 0.0
                        compute_round = {r_sign, 31'b0};
                    end
                end
            end else if (r_exp >= 8'd150) begin
                // Fractional bits are already outside the 23-bit mantissa
                compute_round = a;
            end else begin
                // Normal range with fractional bits inside mantissa (127 <= r_exp < 150)
                mask_shift = 8'd150 - r_exp; 
                frac_mask = ~(24'hFFFFFF << mask_shift);
                mant_mask = ~frac_mask;
                full_mant = {1'b1, r_mant};
                m_int  = full_mant & mant_mask;
                m_frac = full_mant & frac_mask;
                
                if (m_frac != 0) begin
                    round_up = 1'b0;
                    if (op == 4'd2) begin // FLOOR
                        if (r_sign) round_up = 1'b1;
                    end else if (op == 4'd3) begin // CEIL
                        if (!r_sign) round_up = 1'b1;
                    end else if (op == 4'd4) begin // ROUND
                        half = 24'd1 << (mask_shift - 1);
                        if (m_frac > half) round_up = 1'b1;
                        else if (m_frac < half) round_up = 1'b0;
                        else round_up = (m_int >> mask_shift) & 1'b1;
                    end
                    
                    if (round_up) begin
                        m_added = m_int + (25'd1 << mask_shift);
                        if (m_added[24]) begin
                            compute_round = {r_sign, r_exp + 1'b1, m_added[23:1]};
                        end else begin
                            compute_round = {r_sign, r_exp, m_added[22:0]};
                        end
                    end else begin
                        compute_round = {r_sign, r_exp, m_int[22:0]};
                    end
                end else begin
                    compute_round = a;
                end
            end
        end
    endfunction
    
    wire [31:0] round_res = compute_round(a, op);

    // Priority encoder to find leading 1 in 1 clock cycle for NORM
    integer i;
    always @(*) begin
        shift_amt = 24;
        for (i = 23; i >= 0; i = i - 1) begin
            if (mant_res[i] && shift_amt == 24) begin
                shift_amt = 23 - i;
            end
        end
        shifted_mant = mant_res << shift_amt;
    end
    
    // -------------------------------------------------------------------------
    // Combinational min/max/compare logic
    // -------------------------------------------------------------------------
    wire is_nan_a = (a[30:23] == 8'hFF) && (a[22:0] != 23'd0);
    wire is_nan_b = (b[30:23] == 8'hFF) && (b[22:0] != 23'd0);
    wire is_snan_a = is_nan_a && (a[22] == 1'b0);
    wire is_snan_b = is_nan_b && (b[22] == 1'b0);
    
    wire is_zero_a = (a[30:0] == 31'd0);
    wire is_zero_b = (b[30:0] == 31'd0);

    wire a_lt_b_mag = (a[30:0] < b[30:0]);
    wire a_eq_b_mag = (a[30:0] == b[30:0]);

    wire a_eq_b = (is_nan_a || is_nan_b) ? 1'b0 : 
                  (is_zero_a && is_zero_b) ? 1'b1 :
                  (a == b);

    wire a_lt_b = (is_nan_a || is_nan_b) ? 1'b0 :
                  (is_zero_a && is_zero_b) ? 1'b0 :
                  (a[31] != b[31]) ? (a[31] == 1'b1) :
                  (a[31] == 1'b0) ? a_lt_b_mag : (!a_lt_b_mag && !a_eq_b_mag);

    wire a_le_b = a_lt_b || a_eq_b;

    wire min_max_ret_canonical = (is_nan_a && is_nan_b) || is_snan_a || is_snan_b;

    wire [31:0] fmin_res = min_max_ret_canonical ? 32'h7FC00000 : 
                           (is_nan_a) ? b :
                           (is_nan_b) ? a :
                           (is_zero_a && is_zero_b) ? ((a[31] == 1'b1) ? a : b) : 
                           (a_lt_b) ? a : b;

    wire [31:0] fmax_res = min_max_ret_canonical ? 32'h7FC00000 : 
                           (is_nan_a) ? b :
                           (is_nan_b) ? a :
                           (is_zero_a && is_zero_b) ? ((a[31] == 1'b0) ? a : b) : 
                           (a_lt_b) ? b : a;

    // -------------------------------------------------------------------------
    // Combinational float-to-int and int-to-float logic
    // -------------------------------------------------------------------------

    // Float-to-Int (fcvt.w.s = op12, fcvt.wu.s = op13)
    wire [8:0] f2i_exp = {1'b0, a[30:23]};
    wire f2i_sign = a[31];
    wire [31:0] f2i_mant = {8'b0, 1'b1, a[22:0]}; // implicit 1 at bit 23
    wire signed [9:0] f2i_shift = f2i_exp - 10'd127;
    
    // Default zero when shift is negative (less than 1.0)
    wire [31:0] f2i_abs = (f2i_shift < 0) ? 32'b0 :
                          (f2i_shift <= 23) ? (f2i_mant >> (23 - f2i_shift)) : 
                          (f2i_shift <= 31) ? (f2i_mant << (f2i_shift - 23)) : 32'hFFFFFFFF;
                          
    wire over_pos_s = !f2i_sign && (f2i_shift >= 31);
    wire over_neg_s = f2i_sign && (f2i_shift > 31 || (f2i_shift == 31 && a[22:0] != 0));
    
    wire [31:0] f2i_signed_res = 
        (is_nan_a || over_pos_s) ? 32'h7FFFFFFF :
        (over_neg_s) ? 32'h80000000 :
        (f2i_sign ? (~f2i_abs + 1) : f2i_abs);
        
    wire over_pos_u = !f2i_sign && (f2i_shift >= 32);
    wire over_neg_u = f2i_sign && (f2i_shift >= 0 && f2i_abs != 0);
    
    wire [31:0] f2i_unsigned_res = 
        (is_nan_a || over_pos_u) ? 32'hFFFFFFFF :
        (over_neg_u) ? 32'b0 :
        f2i_abs;
    
    // Int-to-Float (fcvt.s.w = op14, fcvt.s.wu = op15)
    wire i2f_is_signed = (op == 4'd14);
    wire i2f_sign = i2f_is_signed && a[31];
    wire [31:0] i2f_abs = (i2f_sign) ? (~a + 1) : a;
    
    reg [4:0] i2f_lz; // Leading zeros
    integer j;
    always @(*) begin
        i2f_lz = 31;
        for (j = 31; j >= 0; j = j - 1) begin
            if (i2f_abs[j] && i2f_lz == 31) begin
                i2f_lz = 31 - j;
            end
        end
    end
    
    wire [7:0] i2f_exp = (i2f_abs == 0) ? 8'd0 : (8'd127 + 8'd31 - {3'b0, i2f_lz});
    
    wire [4:0] shift_left_amt = i2f_lz - 5'd8;
    wire [4:0] shift_right_amt = 5'd8 - i2f_lz;
    
    wire [31:0] i2f_shifted_raw = (i2f_lz <= 8) ? (i2f_abs >> shift_right_amt) : (i2f_abs << shift_left_amt);
    
    // Int-to-Float Round to Nearest Even (RNE)
    wire [7:0] i2f_dropped_mask = (1 << shift_right_amt) - 1;
    wire [7:0] i2f_dropped = (i2f_lz < 8) ? (i2f_abs[7:0] & i2f_dropped_mask) : 8'b0;
    wire [7:0] i2f_half    = (i2f_lz < 8) ? (1 << (shift_right_amt - 1)) : 8'b0;
    
    wire i2f_round_up = (i2f_dropped > i2f_half) || (i2f_dropped == i2f_half && i2f_shifted_raw[0]);
    wire [23:0] i2f_mant_rounded = i2f_shifted_raw[22:0] + i2f_round_up;
    
    wire [7:0] i2f_exp_final = (i2f_abs == 0) ? 8'd0 : i2f_exp + i2f_mant_rounded[23];
    wire [22:0] i2f_mant_final = i2f_mant_rounded[23] ? 23'b0 : i2f_mant_rounded[22:0];
    
    wire [31:0] i2f_res = (i2f_abs == 0) ? 32'b0 : {i2f_sign, i2f_exp_final, i2f_mant_final};

    reg [31:0] fast_path_res;
    always @(*) begin
        case (op)
            4'd7:  fast_path_res = fmin_res;
            4'd8:  fast_path_res = fmax_res;
            4'd9:  fast_path_res = {31'b0, a_eq_b};
            4'd10: fast_path_res = {31'b0, a_lt_b};
            4'd11: fast_path_res = {31'b0, a_le_b};
            4'd12: fast_path_res = f2i_signed_res;
            4'd13: fast_path_res = f2i_unsigned_res;
            4'd14, 4'd15: fast_path_res = i2f_res;
            default: fast_path_res = round_res;
        endcase
    end

    // FPU execute state machine
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            ready <= 1'b0;
            out <= 32'b0;
            fflags <= 5'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (start && !ready) begin // Only trigger if we haven't already processed it
                        if ((op >= 4'd2 && op <= 4'd4) || (op >= 4'd7 && op <= 4'd15)) begin
                            // Fast path for round/floor/ceil and min/max/compare/cvt operations (single-cycle bypass)
                            out <= fast_path_res;
                            ready <= 1'b1;
                            state <= IDLE; // remain in IDLE but wait for start to go low
                        end else begin
                            // Unpack components (handle subnormals correctly without hidden 1)
                            sign_a <= a[31];
                            exp_a  <= {1'b0, a[30:23]};
                            mant_a <= (|a[30:23]) ? {2'b01, a[22:0]} : {2'b00, a[22:0]};
                            
                            // For ADD/SUB, sign_b relies on op==1. For MUL/DIV, compute target sign
                            sign_b <= (op == 4'd1) ? ~b[31] : b[31];
                            exp_b  <= {1'b0, b[30:23]};
                            mant_b <= (|b[30:23]) ? {2'b01, b[22:0]} : {2'b00, b[22:0]};
                            
                            state <= ALIGN_MUL_DIV;
                        end
                    end else if (!start) begin
                        ready <= 1'b0; // Reset ready flag ONLY when start returns to 0
                    end
                end
                
                ALIGN_MUL_DIV: begin
                    if (op == 4'd5) begin
                        // FMUL Logic: sign = sign_a XOR sign_b
                        sign_res <= sign_a ^ sign_b;
                        
                        // Combinational multiplier (could also be made sequential for extreme fMax)
                        out <= out; // Pipeline hold dummy
                        
                        // Product of two 24-bit mantissas is 48 bits.
                        if (({25'b0, mant_a} * {25'b0, mant_b}) & 50'h800000000000) begin
                            mant_res <= ({25'b0, mant_a} * {25'b0, mant_b}) >> 23;
                            exp_res <= {1'b0, exp_a} + {1'b0, exp_b} - 10'd127;
                        end else begin
                            mant_res <= ({25'b0, mant_a} * {25'b0, mant_b}) >> 22;
                            exp_res <= {1'b0, exp_a} + {1'b0, exp_b} - 10'd128;
                        end
                        state <= NORM;
                    end else if (op == 4'd6) begin
                        // FDIV Logic: Initialize shift-and-subtract parameters
                        sign_res <= sign_a ^ sign_b;
                        // 48-bit divided by 24-bit using restoring division
                        div_A <= {mant_a, 23'b0}; // Correct 48-bit assignment
                        div_P <= 48'b0;
                        div_count <= 6'd48;
                        state <= DIVIDE_LOOP;
                    end else begin
                        // FADD / FSUB logic: Align smaller mantissa
                        if (exp_a > exp_b) begin
                            mant_b <= (exp_diff_ab > 24) ? 25'b0 : (mant_b >> exp_diff_ab[4:0]);
                            exp_res <= {1'b0, exp_a};
                        end else if (exp_a < exp_b) begin
                            mant_a <= (exp_diff_ba > 24) ? 25'b0 : (mant_a >> exp_diff_ba[4:0]);
                            exp_res <= {1'b0, exp_b};
                        end else begin
                            exp_res <= {1'b0, exp_a};
                        end
                        state <= ADD;
                    end
                end
                
                ADD: begin
                    // Add or subtract based on signs (For FADD/FSUB only)
                    if (sign_a == sign_b) begin
                        mant_res <= mant_a + mant_b;
                        sign_res <= sign_a;
                    end else begin
                        if (mant_a > mant_b) begin
                            mant_res <= mant_a - mant_b;
                            sign_res <= sign_a;
                        end else if (mant_a < mant_b) begin
                            mant_res <= mant_b - mant_a;
                            sign_res <= sign_b;
                        end else begin
                            mant_res <= 25'b0;
                            sign_res <= 1'b0; // Exact zero cancellation is +0.0
                        end
                    end
                    state <= NORM;
                end
                
                DIVIDE_LOOP: begin
                    if (div_count == 0) begin
                        if (div_A[23]) begin 
                            mant_res <= {1'b0, div_A[23:0]}; // Mantissa aligned (bit 23 = 1)
                            exp_res <= {1'b0, exp_a} - {1'b0, exp_b} + 10'd127;
                        end else begin
                            mant_res <= {1'b0, div_A[22:0], 1'b0}; // Shift left so bit 23 = 1
                            exp_res <= {1'b0, exp_a} - {1'b0, exp_b} + 10'd126;
                        end
                        state <= NORM;
                    end else begin
                        if ({div_P[46:0], div_A[47]} >= {24'b0, mant_b}) begin
                            div_P <= {div_P[46:0], div_A[47]} - {24'b0, mant_b};
                            div_A <= {div_A[46:0], 1'b1};
                        end else begin
                            div_P <= {div_P[46:0], div_A[47]};
                            div_A <= {div_A[46:0], 1'b0};
                        end
                        div_count <= div_count - 1;
                    end
                end
                
                NORM: begin
                    if (mant_res[24]) begin 
                        // Overflowed during addition (Carry Out)
                        if (exp_res >= 10'd254) begin
                            out <= {sign_res, 8'hFF, 23'd0}; // Overflow to Inf
                        end else begin
                            out <= {sign_res, exp_res[7:0] + 8'd1, mant_res[23:1]};
                        end
                        ready <= 1'b1;
                        state <= IDLE;
                    end else if (mant_res == 25'b0) begin 
                        out <= {sign_res, 31'b0};
                        ready <= 1'b1;
                        state <= IDLE;
                    end else if (exp_res <= 10'd0 || exp_res[9]) begin 
                        // Underflow/Subnormal check (handles negative exp due to subtraction in div/mul)
                        out <= {sign_res, 31'b0}; // Simplified Underflow to zero
                        ready <= 1'b1;
                        state <= IDLE;
                    end else if (exp_res <= {5'b0, shift_amt}) begin 
                        // Right shift into subnormal range
                        out <= {sign_res, 8'd0, mant_res[22:0] >> (shift_amt - exp_res[4:0] + 1)};
                        ready <= 1'b1;
                        state <= IDLE;
                    end else begin
                        // Normal execution
                        if ((exp_res - {5'b0, shift_amt}) >= 255) begin
                            out <= {sign_res, 8'hFF, 23'd0};
                        end else begin
                            out <= {sign_res, exp_res[7:0] - {3'b0, shift_amt}, shifted_mant[22:0]};
                        end
                        ready <= 1'b1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
