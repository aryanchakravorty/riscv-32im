`timescale 1ns / 1ps

module tb_fpu_extended;

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

    reg         clk;
    reg         reset;
    reg         start;
    reg [31:0]  operand1;
    reg [31:0]  operand2;
    reg [3:0]   fpu_op;
    wire [31:0] result;
    wire        busy;

    integer total_tests;
    integer total_passed;
    integer total_failed;

    fpu dut (
        .clk(clk),
        .reset(reset),
        .start(start),
        .operand1(operand1),
        .operand2(operand2),
        .fpu_op(fpu_op),
        .result(result),
        .busy(busy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic report_exact;
        input [1023:0] desc;
        input [31:0] expected;
        input [31:0] actual;
        begin
            total_tests = total_tests + 1;
            if (actual === expected) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s | expected=0x%08h actual=0x%08h", desc, expected, actual);
            end else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s | expected=0x%08h actual=0x%08h", desc, expected, actual);
            end
        end
    endtask

    task automatic check_comb_exact;
        input [1023:0] desc;
        input [3:0] op;
        input [31:0] a;
        input [31:0] b;
        input [31:0] expected;
        begin
            @(negedge clk);
            operand1 = a;
            operand2 = b;
            fpu_op = op;
            start = 1'b0;
            #1;
            report_exact(desc, expected, result);
        end
    endtask

    initial begin
        reset = 1'b0;
        start = 1'b0;
        operand1 = 32'h0;
        operand2 = 32'h0;
        fpu_op = OP_FADD;
        total_tests = 0;
        total_passed = 0;
        total_failed = 0;

        #20;
        reset = 1'b1;
        #10;

        $display("\n================== tb_fpu_extended ==================");

        // FMIN / FMAX with NaN inputs (return non-NaN operand)
        check_comb_exact("FMIN NaN,3.0 => 3.0", OP_FMIN, 32'h7FC12345, 32'h40400000, 32'h40400000);
        check_comb_exact("FMIN -2.0,NaN => -2.0", OP_FMIN, 32'hC0000000, 32'h7FC00000, 32'hC0000000);
        check_comb_exact("FMAX NaN,-2.0 => -2.0", OP_FMAX, 32'h7FC12345, 32'hC0000000, 32'hC0000000);
        check_comb_exact("FMAX 3.0,NaN => 3.0", OP_FMAX, 32'h40400000, 32'h7FC00000, 32'h40400000);

        // FEQ / FLT / FLE with NaN (always 0)
        check_comb_exact("FEQ NaN,NaN => 0", OP_FEQ, 32'h7FC00000, 32'h7FC12345, 32'h00000000);
        check_comb_exact("FLT NaN,1.0 => 0", OP_FLT, 32'h7FC12345, 32'h3F800000, 32'h00000000);
        check_comb_exact("FLE 1.0,NaN => 0", OP_FLE, 32'h3F800000, 32'h7FC12345, 32'h00000000);

        // FLR / CEIL / RND on negative numbers
        check_comb_exact("FLR -1.2 => -2", OP_FLR, 32'hBF99999A, 32'h00000000, 32'hFFFFFFFE);
        check_comb_exact("CEIL -1.2 => -1", OP_CEIL, 32'hBF99999A, 32'h00000000, 32'hFFFFFFFF);
        check_comb_exact("RND -2.5 tie-even => -2", OP_RND, 32'hC0200000, 32'h00000000, 32'hFFFFFFFE);

        // FCVT.W.S (float -> signed int), saturation at range boundaries
        check_comb_exact("FCVT.W.S +0.0 => 0", OP_FCVT_W_S, 32'h00000000, 32'h00000000, 32'h00000000);
        check_comb_exact("FCVT.W.S -1.0 => -1", OP_FCVT_W_S, 32'hBF800000, 32'h00000000, 32'hFFFFFFFF);
        check_comb_exact("FCVT.W.S -2^31 => INT_MIN", OP_FCVT_W_S, 32'hCF000000, 32'h00000000, 32'h80000000);
        check_comb_exact("FCVT.W.S +2^31 => INT_MAX(sat)", OP_FCVT_W_S, 32'h4F000000, 32'h00000000, 32'h7FFFFFFF);
        check_comb_exact("FCVT.W.S +very_large => INT_MAX", OP_FCVT_W_S, 32'h7F7FFFFF, 32'h00000000, 32'h7FFFFFFF);

        // FCVT.WU.S (float -> unsigned int), negative clamps to 0
        check_comb_exact("FCVT.WU.S -1.0 => 0(clamp)", OP_FCVT_WU_S, 32'hBF800000, 32'h00000000, 32'h00000000);
        check_comb_exact("FCVT.WU.S -2^31 => 0(clamp)", OP_FCVT_WU_S, 32'hCF000000, 32'h00000000, 32'h00000000);
        check_comb_exact("FCVT.WU.S +0.0 => 0", OP_FCVT_WU_S, 32'h00000000, 32'h00000000, 32'h00000000);
        check_comb_exact("FCVT.WU.S +2^31 => 0x80000000", OP_FCVT_WU_S, 32'h4F000000, 32'h00000000, 32'h80000000);
        check_comb_exact("FCVT.WU.S +2^32 => UINT_MAX(sat)", OP_FCVT_WU_S, 32'h4F800000, 32'h00000000, 32'hFFFFFFFF);
        check_comb_exact("FCVT.WU.S +very_large => UINT_MAX", OP_FCVT_WU_S, 32'h7F7FFFFF, 32'h00000000, 32'hFFFFFFFF);

        // FCVT.S.W (signed int -> float)
        check_comb_exact("FCVT.S.W 0 => +0.0", OP_FCVT_S_W, 32'h00000000, 32'h00000000, 32'h00000000);
        check_comb_exact("FCVT.S.W -1 => -1.0", OP_FCVT_S_W, 32'hFFFFFFFF, 32'h00000000, 32'hBF800000);
        check_comb_exact("FCVT.S.W INT_MAX => 2^31(rounded)", OP_FCVT_S_W, 32'h7FFFFFFF, 32'h00000000, 32'h4F000000);
        check_comb_exact("FCVT.S.W INT_MIN => -2^31", OP_FCVT_S_W, 32'h80000000, 32'h00000000, 32'hCF000000);

        // FCVT.S.WU (unsigned int -> float)
        check_comb_exact("FCVT.S.WU 0 => +0.0", OP_FCVT_S_WU, 32'h00000000, 32'h00000000, 32'h00000000);
        check_comb_exact("FCVT.S.WU 1 => +1.0", OP_FCVT_S_WU, 32'h00000001, 32'h00000000, 32'h3F800000);
        check_comb_exact("FCVT.S.WU 0xFFFFFFFF => 2^32(rounded)", OP_FCVT_S_WU, 32'hFFFFFFFF, 32'h00000000, 32'h4F800000);
        check_comb_exact("FCVT.S.WU 0x80000000 => +2^31", OP_FCVT_S_WU, 32'h80000000, 32'h00000000, 32'h4F000000);

        $display("====================================================");
        $display("Total Tests : %0d", total_tests);
        $display("Passed      : %0d", total_passed);
        $display("Failed      : %0d", total_failed);
        $display("====================================================\n");
        $finish;
    end

endmodule

