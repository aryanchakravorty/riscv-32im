`timescale 1ns / 1ps

module tb_fpu;

    localparam [3:0] OP_FADD = 4'd0,
                     OP_FSUB = 4'd1,
                     OP_FMUL = 4'd2,
                     OP_FDIV = 4'd3;

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

        // (1) Normal numbers including small/large exponents
        check_comb_exact("FADD normal 1.5+2.25", OP_FADD, 32'h3FC00000, 32'h40100000, 32'h40700000);
        check_comb_exact("FSUB normal 10.0-3.25", OP_FSUB, 32'h41200000, 32'h40500000, 32'h40D80000);
        check_comb_exact("FMUL small*large exponents", OP_FMUL, 32'h03800000, 32'h71800000, 32'h35800000);
        check_div_exact ("FDIV normal 7.0/2.0", 32'h40E00000, 32'h40000000, 32'h40600000);

        // (2) Addition with cancellation
        check_comb_exact("FADD cancellation near-equal", OP_FADD, 32'h3F800001, 32'hBF800000, 32'h34000000);

        // (3) NaN input propagates NaN output
        check_comb_exact("FADD NaN propagates", OP_FADD, 32'h7FC12345, 32'h3F800000, 32'h7FC12345);

        // (4) Inf + finite = Inf
        check_comb_exact("FADD Inf + finite", OP_FADD, 32'h7F800000, 32'h40400000, 32'h7F800000);

        // (5) Inf - Inf = NaN
        check_comb_nan("FSUB Inf-Inf NaN", OP_FSUB, 32'h7F800000, 32'h7F800000, 32'h7FC00000);

        // (6) +/-0 handling
        check_comb_exact("FADD +0 + -0 => +0", OP_FADD, 32'h00000000, 32'h80000000, 32'h00000000);
        check_comb_exact("FADD -0 + -0 => -0", OP_FADD, 32'h80000000, 32'h80000000, 32'h80000000);

        // (7) FDIV by zero = +/-Inf
        check_div_exact("FDIV +3.0 / +0 => +Inf", 32'h40400000, 32'h00000000, 32'h7F800000);
        check_div_exact("FDIV -3.0 / +0 => -Inf", 32'hC0400000, 32'h00000000, 32'hFF800000);

        // (8) Round-to-nearest-even tie-break
        check_comb_exact("FADD tie-even 1.0+2^-24", OP_FADD, 32'h3F800000, 32'h33800000, 32'h3F800000);
        check_comb_exact("FADD tie-even odd->up", OP_FADD, 32'h3F800001, 32'h33800000, 32'h3F800002);

        $display("\n================== tb_fpu SUMMARY ==================");
        $display("Total Tests : %0d", total_tests);
        $display("Passed      : %0d", total_passed);
        $display("Failed      : %0d", total_failed);
        $display("====================================================\n");
        $finish;
    end

    task automatic report_exact;
        input [255:0] desc;
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

    task automatic report_nan;
        input [255:0] desc;
        input [31:0] expected_hint;
        input [31:0] actual;
        begin
            total_tests = total_tests + 1;
            if ((actual[30:23] == 8'hFF) && (actual[22:0] != 0)) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s | expected=0x%08h(actual should be NaN) actual=0x%08h", desc, expected_hint, actual);
            end else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s | expected=0x%08h(actual should be NaN) actual=0x%08h", desc, expected_hint, actual);
            end
        end
    endtask

    task automatic check_comb_exact;
        input [255:0] desc;
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

    task automatic check_comb_nan;
        input [255:0] desc;
        input [3:0] op;
        input [31:0] a;
        input [31:0] b;
        input [31:0] expected_hint;
        begin
            @(negedge clk);
            operand1 = a;
            operand2 = b;
            fpu_op = op;
            start = 1'b0;
            #1;
            report_nan(desc, expected_hint, result);
        end
    endtask

    task automatic check_div_exact;
        input [255:0] desc;
        input [31:0] a;
        input [31:0] b;
        input [31:0] expected;
        integer wait_cycles;
        begin
            while (busy) @(negedge clk);

            @(negedge clk);
            operand1 = a;
            operand2 = b;
            fpu_op = OP_FDIV;
            start = 1'b1;

            @(negedge clk);
            start = 1'b0;

            wait_cycles = 0;
            while (busy && (wait_cycles < 200)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end

            if (wait_cycles >= 200) begin
                total_tests = total_tests + 1;
                total_failed = total_failed + 1;
                $display("FAIL: %0s | expected=0x%08h actual=0x%08h (timeout waiting busy=0)", desc, expected, result);
            end else begin
                #1;
                report_exact(desc, expected, result);
            end
        end
    endtask

endmodule
