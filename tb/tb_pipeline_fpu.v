`timescale 1ns / 1ps

module tb_pipeline_fpu;

    reg clk;
    reg reset;
    wire exception;
    wire [31:0] pc_out;

    integer total_tests;
    integer total_passed;
    integer total_failed;
    integer timeout_cycles;

    reg         in_fdiv_stall;
    reg         fdiv_stall_seen;
    integer     fdiv_stall_cycles;
    integer     fdiv_stall_errors;
    reg [31:0]  fdiv_stall_pc;

    integer i;

    pipe DUT (
        .clk(clk),
        .reset(reset),
        .stall(1'b0),
        .exception(exception),
        .pc_out(pc_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic load_program;
        begin
            for (i = 0; i < 1024; i = i + 1)
                DUT.u_imem.mem[i] = 32'h00000013; // NOP

            // Program:
            // (1) fadd.s x3, x1, x2 after LUI bit-pattern loads
            // (2) back-to-back fadd/fmul dependency
            // (3) fdiv then dependent fadd (stall expected)
            // (4) feq result consumed by branch
            // (5) interleaved integer + FPU operations
            DUT.u_imem.mem[0]  = 32'h3FC000B7; // lui   x1, 0x3fc00      (1.5f)
            DUT.u_imem.mem[1]  = 32'h40100137; // lui   x2, 0x40100      (2.25f)
            DUT.u_imem.mem[2]  = 32'h002081D3; // fadd.s x3, x1, x2
            DUT.u_imem.mem[3]  = 32'h00208253; // fadd.s x4, x1, x2
            DUT.u_imem.mem[4]  = 32'h102202D3; // fmul.s x5, x4, x2
            DUT.u_imem.mem[5]  = 32'h18218353; // fdiv.s x6, x3, x2
            DUT.u_imem.mem[6]  = 32'h001303D3; // fadd.s x7, x6, x1 (dependent on fdiv)
            DUT.u_imem.mem[7]  = 32'hA041A453; // feq.s  x8, x3, x4
            DUT.u_imem.mem[8]  = 32'h00040663; // beq    x8, x0, +12 (to mem[11]) -- should NOT take
            DUT.u_imem.mem[9]  = 32'h05500493; // addi   x9, x0, 85
            DUT.u_imem.mem[10] = 32'h0080006F; // jal    x0, +8 (to mem[12])
            DUT.u_imem.mem[11] = 32'h00000493; // addi   x9, x0, 0   (fail path)
            DUT.u_imem.mem[12] = 32'h00700A13; // addi   x20, x0, 7
            DUT.u_imem.mem[13] = 32'h00208AD3; // fadd.s x21, x1, x2
            DUT.u_imem.mem[14] = 32'h01500C13; // addi   x24, x0, 21
            DUT.u_imem.mem[15] = 32'h10208B53; // fmul.s x22, x1, x2
            DUT.u_imem.mem[16] = 32'h00900C93; // addi   x25, x0, 9
            DUT.u_imem.mem[17] = 32'h00E00D13; // addi   x26, x0, 14
            DUT.u_imem.mem[18] = 32'h00100F93; // addi   x31, x0, 1 (done flag)
            DUT.u_imem.mem[19] = 32'h0000006F; // jal    x0, 0 (halt loop)
        end
    endtask

    task automatic check_reg;
        input [1023:0] desc;
        input [4:0]   reg_idx;
        input [31:0]  expected;
        begin
            total_tests = total_tests + 1;
            if (DUT.regs[reg_idx] === expected) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s | reg=x%0d expected=0x%08h actual=0x%08h", desc, reg_idx, expected, DUT.regs[reg_idx]);
            end else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s | reg=x%0d expected=0x%08h actual=0x%08h", desc, reg_idx, expected, DUT.regs[reg_idx]);
            end
        end
    endtask

    task automatic check_condition;
        input [1023:0] desc;
        input         condition;
        input [31:0]  expected_hint;
        input [31:0]  actual_hint;
        begin
            total_tests = total_tests + 1;
            if (condition) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s | expected=0x%08h actual=0x%08h", desc, expected_hint, actual_hint);
            end else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s | expected=0x%08h actual=0x%08h", desc, expected_hint, actual_hint);
            end
        end
    endtask

    // Monitor key architectural state while running.
    initial begin
        $monitor("t=%0t pc=%08h ex_stall=%b fdiv_stall=%b x3=%08h x5=%08h x7=%08h x8=%08h x9=%08h x20=%08h x24=%08h x25=%08h x26=%08h",
                 $time, DUT.pc_out, DUT.ex_stall_out, DUT.u_execute.stall_f_div,
                 DUT.regs[3], DUT.regs[5], DUT.regs[7], DUT.regs[8], DUT.regs[9],
                 DUT.regs[20], DUT.regs[24], DUT.regs[25], DUT.regs[26]);
    end

    // Track FDIV-driven execute stall and verify PC hold while stalled.
    always @(negedge clk) begin
        if (!reset) begin
            in_fdiv_stall    <= 1'b0;
            fdiv_stall_seen  <= 1'b0;
            fdiv_stall_cycles <= 0;
            fdiv_stall_errors <= 0;
            fdiv_stall_pc    <= 32'h0;
        end else begin
            if (!in_fdiv_stall && DUT.u_execute.stall_f_div) begin
                in_fdiv_stall    <= 1'b1;
                fdiv_stall_seen  <= 1'b1;
                fdiv_stall_cycles <= 1;
                fdiv_stall_pc    <= DUT.u_fetch.current_pc;
            end else if (in_fdiv_stall && DUT.u_execute.stall_f_div) begin
                fdiv_stall_cycles <= fdiv_stall_cycles + 1;
                if (DUT.u_fetch.current_pc !== fdiv_stall_pc)
                    fdiv_stall_errors <= fdiv_stall_errors + 1;
            end else if (in_fdiv_stall && !DUT.u_execute.stall_f_div) begin
                in_fdiv_stall <= 1'b0;
            end
        end
    end

    initial begin
        total_tests = 0;
        total_passed = 0;
        total_failed = 0;
        timeout_cycles = 0;

        load_program();

        reset = 1'b0;
        #100;
        reset = 1'b1;

        while ((DUT.regs[31] !== 32'h00000001) && (timeout_cycles < 5000)) begin
            @(negedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        repeat (8) @(negedge clk);

        $display("\n================= PIPELINE FPU CHECKS =================");
        check_condition("Program completed before timeout", (timeout_cycles < 5000), 32'h1, (timeout_cycles < 5000));

        // (1) fadd.s after bit-pattern load
        check_reg("Case1 fadd.s x3=x1+x2", 5'd3, 32'h40700000);

        // (2) back-to-back fadd then fmul dependency (forwarding)
        check_reg("Case2 dependency x4=fadd", 5'd4, 32'h40700000);
        check_reg("Case2 dependency x5=fmul(x4,x2)", 5'd5, 32'h41070000);

        // (3) fdiv followed by dependent fadd, with stall
        check_reg("Case3 fdiv result x6", 5'd6, 32'h3FD55555);
        check_reg("Case3 dependent fadd x7=x6+x1", 5'd7, 32'h404AAAAA);
        check_condition("Case3 fdiv stall asserted", fdiv_stall_seen && (fdiv_stall_cycles > 1), 32'h1, fdiv_stall_cycles[31:0]);
        check_condition("Case3 stall held PC stable", (fdiv_stall_errors == 0), 32'h0, fdiv_stall_errors[31:0]);

        // (4) feq.s result consumed by branch
        check_reg("Case4 feq writes integer 1 to rd(x8)", 5'd8, 32'h00000001);
        check_reg("Case4 branch uses x8 and keeps pass path", 5'd9, 32'h00000055);

        // (5) interleaved integer/FPU operations
        check_reg("Case5 integer addi x20", 5'd20, 32'h00000007);
        check_reg("Case5 interleaved fadd x21", 5'd21, 32'h40700000);
        check_reg("Case5 interleaved fmul x22", 5'd22, 32'h40580000);
        check_reg("Case5 integer addi x24", 5'd24, 32'h00000015);
        check_reg("Case5 integer addi x25", 5'd25, 32'h00000009);
        check_reg("Case5 integer addi x26", 5'd26, 32'h0000000E);

        $display("=======================================================");
        $display("Total Tests : %0d", total_tests);
        $display("Passed      : %0d", total_passed);
        $display("Failed      : %0d", total_failed);
        $display("=======================================================\n");

        if (total_failed == 0) $display("PIPELINE FPU TEST RESULT: PASS");
        else                   $display("PIPELINE FPU TEST RESULT: FAIL");

        $finish;
    end

endmodule

