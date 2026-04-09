`timescale 1ns/1ps

module fpu (
    input               clk,
    input               reset,
    input               start,
    input  [31:0]       operand1,
    input  [31:0]       operand2,
    input  [3:0]        fpu_op,
    output [31:0]       result,
    output              busy
);

localparam [3:0] OP_FADD      = 4'd0,
                 OP_FSUB      = 4'd1,
                 OP_FMUL      = 4'd2,
                 OP_FDIV      = 4'd3,
                 OP_FMIN      = 4'd4,
                 OP_FMAX      = 4'd5,
                 OP_FEQ       = 4'd6,
                 OP_FLT       = 4'd7,
                 OP_FLE       = 4'd8,
                 OP_FLR       = 4'd9,
                 OP_CEIL      = 4'd10,
                 OP_RND       = 4'd11,
                 OP_FCVT_W_S  = 4'd12,
                 OP_FCVT_WU_S = 4'd13,
                 OP_FCVT_S_W  = 4'd14,
                 OP_FCVT_S_WU = 4'd15;

localparam [1:0] IDLE = 2'd0,
                 DIVIDE = 2'd1,
                 ROUND = 2'd2,
                 FINISH = 2'd3;

localparam [1:0] RM_TRUNC = 2'd0,
                 RM_FLOOR = 2'd1,
                 RM_CEIL  = 2'd2,
                 RM_RNE   = 2'd3;

reg [1:0] state;

reg [31:0] result_comb;
reg [31:0] div_result_reg;

reg [5:0]  div_count;
reg [27:0] quotient_reg;
reg [24:0] remainder_reg;
reg [23:0] divisor_reg;
reg        sign_div;
reg signed [11:0] exp_div;

reg [24:0] rem_work;
reg        bit_work;
reg        rem_nonzero;
reg [26:0] round_sig;
reg signed [11:0] round_exp;

reg        sign1, sign2;
reg [7:0]  exp1_raw, exp2_raw;
reg [22:0] frac1, frac2;
reg [23:0] sig1_norm, sig2_norm;
reg [4:0]  shift1, shift2;
reg signed [11:0] exp1_unb, exp2_unb;

assign busy = (state != IDLE) || (start && (fpu_op == OP_FDIV));
assign result = (fpu_op == OP_FDIV) ? div_result_reg : result_comb;

function [31:0] quiet_nan;
    input [31:0] x;
    begin
        if ((x[30:23] == 8'hFF) && (x[22:0] != 0))
            quiet_nan = {x[31], 8'hFF, 1'b1, x[21:0]};
        else
            quiet_nan = 32'h7FC0_0000;
    end
endfunction

function [31:0] propagate_nan2;
    input [31:0] a;
    input [31:0] b;
    begin
        if ((a[30:23] == 8'hFF) && (a[22:0] != 0))
            propagate_nan2 = quiet_nan(a);
        else if ((b[30:23] == 8'hFF) && (b[22:0] != 0))
            propagate_nan2 = quiet_nan(b);
        else
            propagate_nan2 = 32'h7FC0_0000;
    end
endfunction

function [4:0] clz24;
    input [23:0] value;
    integer i;
    begin
        clz24 = 5'd24;
        for (i = 23; i >= 0; i = i - 1) begin
            if (value[i] && (clz24 == 5'd24))
                clz24 = 5'd23 - i;
        end
    end
endfunction

function [63:0] shr_jam64;
    input [63:0] value;
    input [7:0]  dist;
    reg [63:0] mask;
    begin
        if (dist == 0) begin
            shr_jam64 = value;
        end
        else if (dist < 64) begin
            mask = (64'h1 << dist) - 1;
            shr_jam64 = value >> dist;
            if ((value & mask) != 0)
                shr_jam64[0] = 1'b1;
        end
        else begin
            shr_jam64 = (value != 0) ? 64'h1 : 64'h0;
        end
    end
endfunction

function [26:0] shr_jam27;
    input [26:0] value;
    input [7:0]  dist;
    reg [63:0] tmp;
    begin
        tmp = shr_jam64({37'b0, value}, dist);
        shr_jam27 = tmp[26:0];
    end
endfunction

function [31:0] pack_round;
    input               sign;
    input signed [11:0] exp_in;
    input [26:0]        sig_in;
    reg signed [12:0]   exp;
    reg [26:0]          sig;
    reg [24:0]          mant_ext;
    reg [23:0]          mant;
    reg                 increment;
    reg [7:0]           shift_u8;
    reg [8:0]           exp_biased;
    integer             i;
    integer             shift_amt;
    begin
        exp = exp_in;
        sig = sig_in;

        if (sig == 0) begin
            pack_round = {sign, 31'b0};
        end
        else begin
            for (i = 0; i < 27; i = i + 1) begin
                if ((sig[26] == 1'b0) && (sig != 0)) begin
                    sig = sig << 1;
                    exp = exp - 1;
                end
            end

            if (exp < -126) begin
                shift_amt = -126 - exp;
                if (shift_amt > 64) shift_u8 = 8'd64;
                else                shift_u8 = shift_amt[7:0];
                sig = shr_jam27(sig, shift_u8);
                exp = -126;
            end

            mant = sig[26:3];
            increment = sig[2] && (sig[1] || sig[0] || mant[0]);
            mant_ext = {1'b0, mant} + increment;

            if (mant_ext[24]) begin
                mant = mant_ext[24:1];
                exp = exp + 1;
            end
            else begin
                mant = mant_ext[23:0];
            end

            if (mant == 0) begin
                pack_round = {sign, 31'b0};
            end
            else if (exp > 127) begin
                pack_round = {sign, 8'hFF, 23'h0};
            end
            else if ((exp == -126) && (mant[23] == 1'b0)) begin
                pack_round = {sign, 8'h00, mant[22:0]};
            end
            else begin
                exp_biased = exp + 13'sd127;
                pack_round = {sign, exp_biased[7:0], mant[22:0]};
            end
        end
    end
endfunction

function [31:0] fp_addsub;
    input [31:0] a;
    input [31:0] b;
    input        op_sub;
    reg        sign_a, sign_b, sign_b_eff, sign_large, sign_z;
    reg [7:0]  exp_a_raw, exp_b_raw;
    reg [22:0] frac_a, frac_b;
    reg        is_nan_a, is_nan_b, is_inf_a, is_inf_b, is_zero_a, is_zero_b;
    reg [23:0] sig_a, sig_b;
    reg [26:0] sig_a_ext, sig_b_ext, sig_large, sig_small, sig_z;
    reg [27:0] sum_ext;
    reg [26:0] diff_ext;
    reg [4:0]  shift_sub_a, shift_sub_b;
    reg [7:0]  shift_small;
    integer    exp_a, exp_b, exp_large, exp_z;
    integer    shift_amt;
    begin
        sign_a = a[31];
        sign_b = b[31];
        sign_b_eff = sign_b ^ op_sub;
        exp_a_raw = a[30:23];
        exp_b_raw = b[30:23];
        frac_a = a[22:0];
        frac_b = b[22:0];

        is_nan_a  = (exp_a_raw == 8'hFF) && (frac_a != 0);
        is_nan_b  = (exp_b_raw == 8'hFF) && (frac_b != 0);
        is_inf_a  = (exp_a_raw == 8'hFF) && (frac_a == 0);
        is_inf_b  = (exp_b_raw == 8'hFF) && (frac_b == 0);
        is_zero_a = (exp_a_raw == 0)     && (frac_a == 0);
        is_zero_b = (exp_b_raw == 0)     && (frac_b == 0);

        if (is_nan_a || is_nan_b) begin
            fp_addsub = propagate_nan2(a, b);
        end
        else if (is_inf_a || is_inf_b) begin
            if (is_inf_a && is_inf_b) begin
                if (sign_a ^ sign_b_eff) fp_addsub = 32'h7FC0_0000;
                else                     fp_addsub = {sign_a, 8'hFF, 23'h0};
            end
            else if (is_inf_a) begin
                fp_addsub = {sign_a, 8'hFF, 23'h0};
            end
            else begin
                fp_addsub = {sign_b_eff, 8'hFF, 23'h0};
            end
        end
        else if (is_zero_a && is_zero_b) begin
            fp_addsub = {(sign_a & sign_b_eff), 31'b0};
        end
        else if (is_zero_a) begin
            fp_addsub = {sign_b_eff, b[30:0]};
        end
        else if (is_zero_b) begin
            fp_addsub = a;
        end
        else begin
            if (exp_a_raw == 0) begin
                shift_sub_a = clz24({1'b0, frac_a});
                sig_a = ({1'b0, frac_a} << shift_sub_a);
                exp_a = -126 - shift_sub_a;
            end
            else begin
                sig_a = {1'b1, frac_a};
                exp_a = exp_a_raw - 127;
            end

            if (exp_b_raw == 0) begin
                shift_sub_b = clz24({1'b0, frac_b});
                sig_b = ({1'b0, frac_b} << shift_sub_b);
                exp_b = -126 - shift_sub_b;
            end
            else begin
                sig_b = {1'b1, frac_b};
                exp_b = exp_b_raw - 127;
            end

            sig_a_ext = {sig_a, 3'b000};
            sig_b_ext = {sig_b, 3'b000};

            if ((exp_a > exp_b) || ((exp_a == exp_b) && (sig_a >= sig_b))) begin
                exp_large = exp_a;
                sig_large = sig_a_ext;
                sig_small = sig_b_ext;
                sign_large = sign_a;
                shift_amt = exp_a - exp_b;
            end
            else begin
                exp_large = exp_b;
                sig_large = sig_b_ext;
                sig_small = sig_a_ext;
                sign_large = sign_b_eff;
                shift_amt = exp_b - exp_a;
            end

            if (shift_amt > 64) shift_small = 8'd64;
            else                shift_small = shift_amt[7:0];
            sig_small = shr_jam27(sig_small, shift_small);

            if (sign_a == sign_b_eff) begin
                sum_ext = {1'b0, sig_large} + {1'b0, sig_small};
                sign_z = sign_a;
                if (sum_ext[27]) begin
                    sig_z = {sum_ext[27:2], (sum_ext[1] | sum_ext[0])};
                    exp_z = exp_large + 1;
                end
                else begin
                    sig_z = sum_ext[26:0];
                    exp_z = exp_large;
                end
                fp_addsub = pack_round(sign_z, exp_z, sig_z);
            end
            else begin
                if (sig_large == sig_small) begin
                    fp_addsub = 32'h0000_0000;
                end
                else begin
                    diff_ext = sig_large - sig_small;
                    sign_z = sign_large;
                    exp_z = exp_large;
                    fp_addsub = pack_round(sign_z, exp_z, diff_ext);
                end
            end
        end
    end
endfunction

function [31:0] fp_mul;
    input [31:0] a;
    input [31:0] b;
    reg        sign_a, sign_b, sign_z;
    reg [7:0]  exp_a_raw, exp_b_raw;
    reg [22:0] frac_a, frac_b;
    reg        is_nan_a, is_nan_b, is_inf_a, is_inf_b, is_zero_a, is_zero_b;
    reg [23:0] sig_a, sig_b;
    reg [47:0] prod;
    reg [26:0] sig_z;
    reg [4:0]  shift_sub_a, shift_sub_b;
    integer    exp_a, exp_b, exp_z;
    begin
        sign_a = a[31];
        sign_b = b[31];
        sign_z = sign_a ^ sign_b;
        exp_a_raw = a[30:23];
        exp_b_raw = b[30:23];
        frac_a = a[22:0];
        frac_b = b[22:0];

        is_nan_a  = (exp_a_raw == 8'hFF) && (frac_a != 0);
        is_nan_b  = (exp_b_raw == 8'hFF) && (frac_b != 0);
        is_inf_a  = (exp_a_raw == 8'hFF) && (frac_a == 0);
        is_inf_b  = (exp_b_raw == 8'hFF) && (frac_b == 0);
        is_zero_a = (exp_a_raw == 0)     && (frac_a == 0);
        is_zero_b = (exp_b_raw == 0)     && (frac_b == 0);

        if (is_nan_a || is_nan_b) begin
            fp_mul = propagate_nan2(a, b);
        end
        else if ((is_inf_a && is_zero_b) || (is_inf_b && is_zero_a)) begin
            fp_mul = 32'h7FC0_0000;
        end
        else if (is_inf_a || is_inf_b) begin
            fp_mul = {sign_z, 8'hFF, 23'h0};
        end
        else if (is_zero_a || is_zero_b) begin
            fp_mul = {sign_z, 31'b0};
        end
        else begin
            if (exp_a_raw == 0) begin
                shift_sub_a = clz24({1'b0, frac_a});
                sig_a = ({1'b0, frac_a} << shift_sub_a);
                exp_a = -126 - shift_sub_a;
            end
            else begin
                sig_a = {1'b1, frac_a};
                exp_a = exp_a_raw - 127;
            end

            if (exp_b_raw == 0) begin
                shift_sub_b = clz24({1'b0, frac_b});
                sig_b = ({1'b0, frac_b} << shift_sub_b);
                exp_b = -126 - shift_sub_b;
            end
            else begin
                sig_b = {1'b1, frac_b};
                exp_b = exp_b_raw - 127;
            end

            exp_z = exp_a + exp_b;
            prod = sig_a * sig_b;

            if (prod[47]) begin
                sig_z = {prod[47:22], (prod[21] | (|prod[20:0]))};
                exp_z = exp_z + 1;
            end
            else begin
                sig_z = {prod[46:21], (prod[20] | (|prod[19:0]))};
            end

            fp_mul = pack_round(sign_z, exp_z, sig_z);
        end
    end
endfunction

function is_nan32;
    input [31:0] x;
    begin
        is_nan32 = (x[30:23] == 8'hFF) && (x[22:0] != 0);
    end
endfunction

function fp_eq_num;
    input [31:0] a;
    input [31:0] b;
    begin
        if ((a[30:0] == 0) && (b[30:0] == 0))
            fp_eq_num = 1'b1;
        else
            fp_eq_num = (a == b);
    end
endfunction

function fp_lt_num;
    input [31:0] a;
    input [31:0] b;
    begin
        if ((a[30:0] == 0) && (b[30:0] == 0))
            fp_lt_num = 1'b0;
        else if (a[31] ^ b[31])
            fp_lt_num = a[31];
        else if (!a[31])
            fp_lt_num = (a[30:0] < b[30:0]);
        else
            fp_lt_num = (a[30:0] > b[30:0]);
    end
endfunction

function [31:0] fp_min;
    input [31:0] a;
    input [31:0] b;
    reg nan_a, nan_b;
    begin
        nan_a = is_nan32(a);
        nan_b = is_nan32(b);

        if (nan_a && nan_b)
            fp_min = 32'h7FC0_0000;
        else if (nan_a)
            fp_min = b;
        else if (nan_b)
            fp_min = a;
        else if ((a[30:0] == 0) && (b[30:0] == 0))
            fp_min = {(a[31] | b[31]), 31'b0};
        else if (fp_lt_num(a, b))
            fp_min = a;
        else
            fp_min = b;
    end
endfunction

function [31:0] fp_max;
    input [31:0] a;
    input [31:0] b;
    reg nan_a, nan_b;
    begin
        nan_a = is_nan32(a);
        nan_b = is_nan32(b);

        if (nan_a && nan_b)
            fp_max = 32'h7FC0_0000;
        else if (nan_a)
            fp_max = b;
        else if (nan_b)
            fp_max = a;
        else if ((a[30:0] == 0) && (b[30:0] == 0))
            fp_max = {(a[31] & b[31]), 31'b0};
        else if (fp_lt_num(a, b))
            fp_max = b;
        else
            fp_max = a;
    end
endfunction

function [31:0] float_to_int_signed_mode;
    input [31:0] a;
    input [1:0]  mode;
    reg          sign;
    reg [7:0]    exp_raw;
    reg [22:0]   frac;
    reg [23:0]   sig;
    reg          nonzero;
    integer      exp;
    integer      shift;
    reg [63:0]   mag_int;
    reg [63:0]   rem;
    reg [63:0]   mask;
    reg [63:0]   half;
    reg [63:0]   rounded_mag;
    begin
        sign = a[31];
        exp_raw = a[30:23];
        frac = a[22:0];
        nonzero = (a[30:0] != 0);

        if ((exp_raw == 8'hFF) && (frac != 0)) begin
            float_to_int_signed_mode = 32'h7FFF_FFFF;
        end
        else if (exp_raw == 8'hFF) begin
            float_to_int_signed_mode = sign ? 32'h8000_0000 : 32'h7FFF_FFFF;
        end
        else if (!nonzero) begin
            float_to_int_signed_mode = 32'h0000_0000;
        end
        else begin
            if (exp_raw == 0) begin
                exp = -126;
                sig = {1'b0, frac};
            end
            else begin
                exp = exp_raw - 127;
                sig = {1'b1, frac};
            end

            if (exp > 31) begin
                float_to_int_signed_mode = sign ? 32'h8000_0000 : 32'h7FFF_FFFF;
            end
            else if (exp < -1) begin
                case (mode)
                    RM_FLOOR: float_to_int_signed_mode = sign ? 32'hFFFF_FFFF : 32'h0000_0000;
                    RM_CEIL:  float_to_int_signed_mode = sign ? 32'h0000_0000 : 32'h0000_0001;
                    default:  float_to_int_signed_mode = 32'h0000_0000;
                endcase
            end
            else begin
                mag_int = 64'd0;
                rem = 64'd0;
                if (exp >= 23) begin
                    shift = exp - 23;
                    mag_int = {40'b0, sig} << shift;
                end
                else begin
                    shift = 23 - exp;
                    mag_int = {40'b0, sig} >> shift;
                    mask = (64'h1 << shift) - 1;
                    rem = {40'b0, sig} & mask;
                end

                rounded_mag = mag_int;
                if ((exp < 23) && (rem != 0)) begin
                    case (mode)
                        RM_FLOOR: if (sign) rounded_mag = mag_int + 1'b1;
                        RM_CEIL:  if (!sign) rounded_mag = mag_int + 1'b1;
                        RM_RNE: begin
                            half = 64'h1 << (shift - 1);
                            if ((rem > half) || ((rem == half) && mag_int[0]))
                                rounded_mag = mag_int + 1'b1;
                        end
                        default: ;
                    endcase
                end

                if (sign) begin
                    if (rounded_mag >= 64'd2147483648)
                        float_to_int_signed_mode = 32'h8000_0000;
                    else
                        float_to_int_signed_mode = (~rounded_mag[31:0]) + 1'b1;
                end
                else begin
                    if (rounded_mag >= 64'd2147483648)
                        float_to_int_signed_mode = 32'h7FFF_FFFF;
                    else
                        float_to_int_signed_mode = rounded_mag[31:0];
                end
            end
        end
    end
endfunction

function [31:0] float_to_int_unsigned_mode;
    input [31:0] a;
    input [1:0]  mode;
    reg          sign;
    reg [7:0]    exp_raw;
    reg [22:0]   frac;
    reg [23:0]   sig;
    reg          nonzero;
    integer      exp;
    integer      shift;
    reg [63:0]   mag_int;
    reg [63:0]   rem;
    reg [63:0]   mask;
    reg [63:0]   half;
    reg [63:0]   rounded_mag;
    begin
        sign = a[31];
        exp_raw = a[30:23];
        frac = a[22:0];
        nonzero = (a[30:0] != 0);

        if ((exp_raw == 8'hFF) && (frac != 0)) begin
            float_to_int_unsigned_mode = 32'hFFFF_FFFF;
        end
        else if (exp_raw == 8'hFF) begin
            float_to_int_unsigned_mode = sign ? 32'h0000_0000 : 32'hFFFF_FFFF;
        end
        else if (!nonzero) begin
            float_to_int_unsigned_mode = 32'h0000_0000;
        end
        else if (sign) begin
            float_to_int_unsigned_mode = 32'h0000_0000;
        end
        else begin
            if (exp_raw == 0) begin
                exp = -126;
                sig = {1'b0, frac};
            end
            else begin
                exp = exp_raw - 127;
                sig = {1'b1, frac};
            end

            if (exp > 31) begin
                float_to_int_unsigned_mode = 32'hFFFF_FFFF;
            end
            else if (exp < -1) begin
                case (mode)
                    RM_CEIL:  float_to_int_unsigned_mode = 32'h0000_0001;
                    default:  float_to_int_unsigned_mode = 32'h0000_0000;
                endcase
            end
            else begin
                mag_int = 64'd0;
                rem = 64'd0;
                if (exp >= 23) begin
                    shift = exp - 23;
                    mag_int = {40'b0, sig} << shift;
                end
                else begin
                    shift = 23 - exp;
                    mag_int = {40'b0, sig} >> shift;
                    mask = (64'h1 << shift) - 1;
                    rem = {40'b0, sig} & mask;
                end

                rounded_mag = mag_int;
                if ((exp < 23) && (rem != 0)) begin
                    case (mode)
                        RM_CEIL: rounded_mag = mag_int + 1'b1;
                        RM_RNE: begin
                            half = 64'h1 << (shift - 1);
                            if ((rem > half) || ((rem == half) && mag_int[0]))
                                rounded_mag = mag_int + 1'b1;
                        end
                        default: ;
                    endcase
                end

                if (rounded_mag >= 64'd4294967296)
                    float_to_int_unsigned_mode = 32'hFFFF_FFFF;
                else
                    float_to_int_unsigned_mode = rounded_mag[31:0];
            end
        end
    end
endfunction

function [31:0] uint_to_fp;
    input [31:0] u;
    reg [23:0] mant24;
    reg [24:0] mant25;
    reg [31:0] rem_mask;
    reg [31:0] rem;
    reg [31:0] half;
    reg [7:0]  exp_raw;
    integer msb;
    integer shift;
    integer i;
    begin
        if (u == 0) begin
            uint_to_fp = 32'h0000_0000;
        end
        else begin
            msb = -1;
            for (i = 31; i >= 0; i = i - 1) begin
                if (u[i] && (msb < 0))
                    msb = i;
            end

            if (msb <= 23) begin
                mant24 = u << (23 - msb);
            end
            else begin
                shift = msb - 23;
                mant24 = u >> shift;

                rem_mask = (32'h1 << shift) - 1;
                rem = u & rem_mask;
                half = 32'h1 << (shift - 1);
                mant25 = {1'b0, mant24};
                if ((rem > half) || ((rem == half) && mant24[0]))
                    mant25 = mant25 + 1'b1;

                if (mant25[24]) begin
                    mant24 = mant25[24:1];
                    msb = msb + 1;
                end
                else begin
                    mant24 = mant25[23:0];
                end
            end

            exp_raw = msb + 127;
            uint_to_fp = {1'b0, exp_raw, mant24[22:0]};
        end
    end
endfunction

function [31:0] int_to_fp_signed;
    input [31:0] w;
    reg        sign;
    reg [31:0] mag;
    reg [31:0] mag_fp;
    begin
        if (w == 0) begin
            int_to_fp_signed = 32'h0000_0000;
        end
        else begin
            sign = w[31];
            mag = sign ? ((~w) + 1'b1) : w;
            mag_fp = uint_to_fp(mag);
            int_to_fp_signed = {sign, mag_fp[30:0]};
        end
    end
endfunction

always @(*) begin
    case (fpu_op)
        OP_FADD:      result_comb = fp_addsub(operand1, operand2, 1'b0);
        OP_FSUB:      result_comb = fp_addsub(operand1, operand2, 1'b1);
        OP_FMUL:      result_comb = fp_mul(operand1, operand2);
        OP_FMIN:      result_comb = fp_min(operand1, operand2);
        OP_FMAX:      result_comb = fp_max(operand1, operand2);
        OP_FEQ:       result_comb = {31'b0, (!is_nan32(operand1) && !is_nan32(operand2) && fp_eq_num(operand1, operand2))};
        OP_FLT:       result_comb = {31'b0, (!is_nan32(operand1) && !is_nan32(operand2) && fp_lt_num(operand1, operand2))};
        OP_FLE:       result_comb = {31'b0, (!is_nan32(operand1) && !is_nan32(operand2) &&
                                             (fp_lt_num(operand1, operand2) || fp_eq_num(operand1, operand2)))};
        OP_FLR:       result_comb = float_to_int_signed_mode(operand1, RM_FLOOR);
        OP_CEIL:      result_comb = float_to_int_signed_mode(operand1, RM_CEIL);
        OP_RND:       result_comb = float_to_int_signed_mode(operand1, RM_RNE);
        OP_FCVT_W_S:  result_comb = float_to_int_signed_mode(operand1, RM_TRUNC);
        OP_FCVT_WU_S: result_comb = float_to_int_unsigned_mode(operand1, RM_TRUNC);
        OP_FCVT_S_W:  result_comb = int_to_fp_signed(operand1);
        OP_FCVT_S_WU: result_comb = uint_to_fp(operand1);
        default: result_comb = 32'h0;
    endcase
end

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        state         <= IDLE;
        div_count     <= 6'd0;
        quotient_reg  <= 28'd0;
        remainder_reg <= 25'd0;
        divisor_reg   <= 24'd0;
        sign_div      <= 1'b0;
        exp_div       <= 12'sd0;
        div_result_reg <= 32'h0;
    end
    else begin
        case (state)
            IDLE: begin
                if (start && (fpu_op == OP_FDIV)) begin
                    sign1 = operand1[31];
                    sign2 = operand2[31];
                    exp1_raw = operand1[30:23];
                    exp2_raw = operand2[30:23];
                    frac1 = operand1[22:0];
                    frac2 = operand2[22:0];

                    if (((exp1_raw == 8'hFF) && (frac1 != 0)) ||
                        ((exp2_raw == 8'hFF) && (frac2 != 0))) begin
                        div_result_reg <= propagate_nan2(operand1, operand2);
                        state <= FINISH;
                    end
                    else if ((exp1_raw == 8'hFF) && (exp2_raw == 8'hFF) && (frac1 == 0) && (frac2 == 0)) begin
                        div_result_reg <= 32'h7FC0_0000;
                        state <= FINISH;
                    end
                    else if ((exp1_raw == 0) && (frac1 == 0) && (exp2_raw == 0) && (frac2 == 0)) begin
                        div_result_reg <= 32'h7FC0_0000;
                        state <= FINISH;
                    end
                    else if ((exp1_raw == 8'hFF) && (frac1 == 0)) begin
                        div_result_reg <= {sign1 ^ sign2, 8'hFF, 23'h0};
                        state <= FINISH;
                    end
                    else if ((exp2_raw == 8'hFF) && (frac2 == 0)) begin
                        div_result_reg <= {sign1 ^ sign2, 31'b0};
                        state <= FINISH;
                    end
                    else if ((exp2_raw == 0) && (frac2 == 0)) begin
                        div_result_reg <= {sign1 ^ sign2, 8'hFF, 23'h0};
                        state <= FINISH;
                    end
                    else if ((exp1_raw == 0) && (frac1 == 0)) begin
                        div_result_reg <= {sign1 ^ sign2, 31'b0};
                        state <= FINISH;
                    end
                    else begin
                        if (exp1_raw == 0) begin
                            shift1 = clz24({1'b0, frac1});
                            sig1_norm = ({1'b0, frac1} << shift1);
                            exp1_unb = -126 - shift1;
                        end
                        else begin
                            sig1_norm = {1'b1, frac1};
                            exp1_unb = exp1_raw - 127;
                        end

                        if (exp2_raw == 0) begin
                            shift2 = clz24({1'b0, frac2});
                            sig2_norm = ({1'b0, frac2} << shift2);
                            exp2_unb = -126 - shift2;
                        end
                        else begin
                            sig2_norm = {1'b1, frac2};
                            exp2_unb = exp2_raw - 127;
                        end

                        sign_div <= sign1 ^ sign2;
                        exp_div <= exp1_unb - exp2_unb;
                        divisor_reg <= sig2_norm;
                        div_count <= 6'd27;

                        if (sig1_norm >= sig2_norm) begin
                            quotient_reg <= {1'b1, 27'b0};
                            remainder_reg <= {1'b0, (sig1_norm - sig2_norm)};
                        end
                        else begin
                            quotient_reg <= 28'b0;
                            remainder_reg <= {1'b0, sig1_norm};
                        end

                        state <= DIVIDE;
                    end
                end
            end

            DIVIDE: begin
                rem_work = {remainder_reg[23:0], 1'b0};
                if (rem_work >= {1'b0, divisor_reg}) begin
                    rem_work = rem_work - {1'b0, divisor_reg};
                    bit_work = 1'b1;
                end
                else begin
                    bit_work = 1'b0;
                end

                remainder_reg <= rem_work;
                quotient_reg[div_count - 1] <= bit_work;

                if (div_count == 6'd1) begin
                    div_count <= 6'd0;
                    state <= ROUND;
                end
                else begin
                    div_count <= div_count - 1'b1;
                end
            end

            ROUND: begin
                rem_nonzero = (remainder_reg != 0);
                if (quotient_reg[27]) begin
                    round_sig = {quotient_reg[27:2], (quotient_reg[1] | quotient_reg[0] | rem_nonzero)};
                    round_exp = exp_div;
                end
                else begin
                    round_sig = {quotient_reg[26:1], (quotient_reg[0] | rem_nonzero)};
                    round_exp = exp_div - 1;
                end
                div_result_reg <= pack_round(sign_div, round_exp, round_sig);
                state <= FINISH;
            end

            FINISH: begin
                state <= IDLE;
            end

            default: begin
                state <= IDLE;
            end
        endcase
    end
end

endmodule
