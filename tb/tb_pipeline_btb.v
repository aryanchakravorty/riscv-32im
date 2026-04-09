`timescale 1ns / 1ps

module tb_pipeline_btb;

    reg clk;
    reg reset;
    wire exception;
    wire [31:0] pc_out;

    integer total_tests;
    integer total_passed;
    integer total_failed;
    integer timeout_cycles;

    integer total_flush_cycles;
    integer mispredict_cycles;
    integer loop_branch_events;
    integer jal_events;

    reg first_loop_seen,  first_loop_pass;
    reg second_loop_seen, second_loop_pass;
    reg exit_loop_seen,   exit_loop_pass;
    reg jal_second_seen,  jal_second_pass;

    integer i;
    integer fd;
    reg program_loaded;

    localparam [31:0] LOOP_BRANCH_PC = 32'h00000014; // bne x1, x0, loop
    localparam [31:0] LOOP_TARGET    = 32'h00000008; // loop body start
    localparam [31:0] JAL_PC         = 32'h0000000C; // jal x0, +4
    localparam [31:0] JAL_TARGET     = 32'h00000010;

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

    task automatic load_program_hex;
        begin
            for (i = 0; i < 1024; i = i + 1)
                DUT.u_imem.mem[i] = 32'h00000013; // NOP

            program_loaded = 1'b0;

            fd = $fopen("pipeline_btb_imem.hex", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("pipeline_btb_imem.hex", DUT.u_imem.mem);
                program_loaded = 1'b1;
                $display("Loaded program from pipeline_btb_imem.hex");
            end

            if (!program_loaded) begin
                fd = $fopen("../../../../pipeline_btb_imem.hex", "r");
                if (fd != 0) begin
                    $fclose(fd);
                    $readmemh("../../../../pipeline_btb_imem.hex", DUT.u_imem.mem);
                    program_loaded = 1'b1;
                    $display("Loaded program from ../../../../pipeline_btb_imem.hex");
                end
            end

            if (!program_loaded) begin
                $display("FAIL: Could not locate pipeline_btb_imem.hex for $readmemh");
                $finish;
            end
        end
    endtask

    task automatic check_condition;
        input [1023:0] desc;
        input          condition;
        input [31:0]   expected;
        input [31:0]   actual;
        begin
            total_tests = total_tests + 1;
            if (condition) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s | expected=0x%08h actual=0x%08h", desc, expected, actual);
            end else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s | expected=0x%08h actual=0x%08h", desc, expected, actual);
            end
        end
    endtask

    task automatic check_reg;
        input [1023:0] desc;
        input [4:0]    reg_idx;
        input [31:0]   expected;
        begin
            total_tests = total_tests + 1;
            if (DUT.regs[reg_idx] === expected) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s | x%0d expected=0x%08h actual=0x%08h", desc, reg_idx, expected, DUT.regs[reg_idx]);
            end else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s | x%0d expected=0x%08h actual=0x%08h", desc, reg_idx, expected, DUT.regs[reg_idx]);
            end
        end
    endtask

    initial begin
        $monitor("t=%0t pc=%08h mispredict=%b branch_taken=%b ex_predicted_taken=%b ex_btb_pc=%08h ex_btb_target=%08h flush_if=%b flush_id=%b x1=%08h x2=%08h x3=%08h x8=%08h",
                 $time, DUT.pc_out, DUT.mispredict, DUT.branch_taken, DUT.ex_predicted_taken,
                 DUT.ex_btb_pc, DUT.ex_btb_target, DUT.flush_if, DUT.flush_id,
                 DUT.regs[1], DUT.regs[2], DUT.regs[3], DUT.regs[8]);
    end

    always @(negedge clk) begin
        if (!reset) begin
            total_flush_cycles = 0;
            mispredict_cycles = 0;
            loop_branch_events = 0;
            jal_events = 0;
            first_loop_seen = 0;  first_loop_pass = 0;
            second_loop_seen = 0; second_loop_pass = 0;
            exit_loop_seen = 0;   exit_loop_pass = 0;
            jal_second_seen = 0;  jal_second_pass = 0;
        end else begin
            if (DUT.mispredict) mispredict_cycles = mispredict_cycles + 1;
            if (DUT.flush_if) total_flush_cycles = total_flush_cycles + 1;
            if (DUT.flush_id) total_flush_cycles = total_flush_cycles + 1;

            if (DUT.branch_resolved && (DUT.id_btb_pc == LOOP_BRANCH_PC)) begin
                loop_branch_events = loop_branch_events + 1;

                if (loop_branch_events == 1) begin
                    first_loop_seen = 1'b1;
                    first_loop_pass = DUT.branch_taken &&
                                      (DUT.id_predicted_taken == 1'b0) &&
                                      DUT.mispredict &&
                                      DUT.flush_if && DUT.flush_id;
                end

                if (loop_branch_events == 2) begin
                    second_loop_seen = 1'b1;
                    second_loop_pass = DUT.branch_taken &&
                                       DUT.id_predicted_taken &&
                                       (DUT.id_btb_target == LOOP_TARGET) &&
                                       (DUT.mispredict == 1'b0) &&
                                       (DUT.flush_if == 1'b0) &&
                                       (DUT.flush_id == 1'b0);
                end

                if (!DUT.branch_taken) begin
                    exit_loop_seen = 1'b1;
                    exit_loop_pass = DUT.id_predicted_taken &&
                                     (DUT.id_btb_target == LOOP_TARGET) &&
                                     DUT.mispredict &&
                                     DUT.flush_if && DUT.flush_id;
                end
            end

            if (DUT.branch_resolved && (DUT.id_btb_pc == JAL_PC)) begin
                jal_events = jal_events + 1;
                if (jal_events == 2) begin
                    jal_second_seen = 1'b1;
                    jal_second_pass = DUT.branch_taken &&
                                      DUT.id_predicted_taken &&
                                      (DUT.id_btb_target == JAL_TARGET) &&
                                      (DUT.mispredict == 1'b0) &&
                                      (DUT.flush_if == 1'b0) &&
                                      (DUT.flush_id == 1'b0);
                end
            end
        end
    end

    initial begin
        total_tests = 0;
        total_passed = 0;
        total_failed = 0;
        timeout_cycles = 0;

        #1;
        load_program_hex();

        reset = 1'b0;
        #100;
        reset = 1'b1;

        while ((DUT.regs[31] !== 32'h00000001) && (timeout_cycles < 40000)) begin
            @(negedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        repeat (8) @(negedge clk);

        $display("\n================ PIPELINE BTB CHECKS ================");

        check_condition("Program completed before timeout", (timeout_cycles < 40000), 32'h00000001, (timeout_cycles < 40000));

        check_condition("First loop branch: cold miss -> mispredict + 2-stage flush",
                        first_loop_seen && first_loop_pass, 32'h00000001, first_loop_seen && first_loop_pass);

        check_condition("Second loop branch: warm hit taken, target-correct -> no flush",
                        second_loop_seen && second_loop_pass, 32'h00000001, second_loop_seen && second_loop_pass);

        check_condition("Loop exit: predicted taken but actual not-taken -> mispredict + 2-stage flush",
                        exit_loop_seen && exit_loop_pass, 32'h00000001, exit_loop_seen && exit_loop_pass);

        check_condition("Second JAL encounter: warm hit target-correct -> no flush",
                        jal_second_seen && jal_second_pass, 32'h00000001, jal_second_seen && jal_second_pass);

        check_condition("Loop branch resolved exactly 8 times", (loop_branch_events == 8), 32'h00000008, loop_branch_events[31:0]);
        check_condition("JAL resolved at least twice", (jal_events >= 2), 32'h00000002, jal_events[31:0]);

        // Interleaved integer operations correctness
        check_reg("Interleaved integer loop accumulation x2", 5'd2, 32'd24);
        check_reg("Post-loop copy x3", 5'd3, 32'd24);
        check_reg("Loop counter exhausted x1", 5'd1, 32'd0);
        check_reg("Marker register x8", 5'd8, 32'h00000055);
        check_reg("Done flag x31", 5'd31, 32'h00000001);

        $display("Total mispredict cycles observed : %0d", mispredict_cycles);
        $display("Total flush cycles (IF+ID slots) : %0d", total_flush_cycles);
        $display("======================================================");
        $display("Total Tests : %0d", total_tests);
        $display("Passed      : %0d", total_passed);
        $display("Failed      : %0d", total_failed);
        $display("======================================================\n");

        if (total_failed == 0) $display("PIPELINE BTB TEST RESULT: PASS");
        else                   $display("PIPELINE BTB TEST RESULT: FAIL");

        $finish;
    end

endmodule

