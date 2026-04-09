`timescale 1ns/1ps

module tb_fetch_btb;

    reg         clk;
    reg         reset; // active-low
    reg         stall;
    reg         flush;
    reg         branch_taken;
    reg [31:0]  branch_target;

    reg         btb_update_en;
    reg [31:0]  btb_update_pc;
    reg         btb_actual_taken;
    reg [31:0]  btb_actual_target;

    reg [31:0]  imem_data;
    reg         imem_stall;

    wire [31:0] pc_out;
    wire [31:0] pc_plus4_out;
    wire [31:0] instruction_out;
    wire        valid_out;
    wire [31:0] current_pc;
    wire        predicted_taken_out;
    wire [31:0] btb_target_out;
    wire [31:0] btb_pc_out;

    integer total_tests;
    integer total_passed;
    integer total_failed;

    reg [31:0] prev_pc;
    reg [31:0] hold_pc, hold_pc_out, hold_btb_pc, hold_btb_tgt;
    reg        hold_pred;

    localparam [31:0] PC_BASE   = 32'h00000100;
    localparam [31:0] TARGET_1  = 32'h00000180;
    localparam [31:0] TARGET_2  = 32'h000001A0;
    localparam [31:0] CORR_TGT  = 32'h00000300;

    // Mock icache data: always a branch instruction (beq x0, x0, 0)
    localparam [31:0] MOCK_BRANCH_INST = 32'h00000063;

    fetch #(
        .RESET(PC_BASE)
    ) DUT (
        .clk(clk),
        .reset(reset),
        .stall(stall),
        .flush(flush),
        .branch_taken(branch_taken),
        .branch_target(branch_target),
        .btb_update_en(btb_update_en),
        .btb_update_pc(btb_update_pc),
        .btb_actual_taken(btb_actual_taken),
        .btb_actual_target(btb_actual_target),
        .imem_data(imem_data),
        .imem_stall(imem_stall),
        .pc_out(pc_out),
        .pc_plus4_out(pc_plus4_out),
        .instruction_out(instruction_out),
        .valid_out(valid_out),
        .current_pc(current_pc),
        .predicted_taken_out(predicted_taken_out),
        .btb_target_out(btb_target_out),
        .btb_pc_out(btb_pc_out)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // #10 period
    end

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic report_case;
        input [1023:0] name;
        input          pass_cond;
        begin
            total_tests = total_tests + 1;
            if (pass_cond) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s", name);
            end else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s", name);
            end
        end
    endtask

    initial begin
        // Defaults
        reset = 1'b0;
        stall = 1'b0;
        flush = 1'b0;
        branch_taken = 1'b0;
        branch_target = 32'h0;
        btb_update_en = 1'b0;
        btb_update_pc = 32'h0;
        btb_actual_taken = 1'b0;
        btb_actual_target = 32'h0;
        imem_data = MOCK_BRANCH_INST;
        imem_stall = 1'b0;
        total_tests = 0;
        total_passed = 0;
        total_failed = 0;

        // Reset for 2 cycles
        tick();
        tick();
        reset = 1'b1;
        #1;

        // 1) Cold start: no BTB entry => sequential pc+4
        prev_pc = current_pc;
        tick();
        report_case("Cold start uses pc+4 when BTB misses",
                    (current_pc == (prev_pc + 32'd4)));

        // 2) Manual BTB update at PC=0x100 => next fetch from 0x100 predicts 0x180
        //    Hold PC at 0x100 while writing and then priming BTB lookup.
        branch_taken = 1'b1;
        branch_target = PC_BASE;
        btb_update_en = 1'b1;
        btb_update_pc = PC_BASE;
        btb_actual_taken = 1'b1;
        btb_actual_target = TARGET_1;
        tick(); // write BTB entry

        btb_update_en = 1'b0;
        tick(); // BTB lookup output for PC_BASE becomes valid/taken/target

        branch_taken = 1'b0;
        tick(); // consume BTB prediction
        report_case("Warm hit predicts taken with target 0x180",
                    (current_pc == TARGET_1) &&
                    (predicted_taken_out == 1'b1) &&
                    (btb_target_out == TARGET_1));

        // 3) Correction override has highest priority over BTB prediction
        //    First create/prime a conflicting BTB prediction for current PC (0x180 -> 0x1A0),
        //    then assert branch_taken with target 0x300 and verify override.
        branch_taken = 1'b1;
        branch_target = TARGET_1;
        btb_update_en = 1'b1;
        btb_update_pc = TARGET_1;
        btb_actual_taken = 1'b1;
        btb_actual_target = TARGET_2;
        tick(); // write entry

        btb_update_en = 1'b0;
        tick(); // prime lookup prediction for 0x180

        branch_taken = 1'b1;
        branch_target = CORR_TGT;
        tick();
        report_case("Branch correction override beats BTB prediction",
                    (current_pc == CORR_TGT));

        // 4) Stall holds PC and output registers
        branch_taken = 1'b0;
        hold_pc = current_pc;
        hold_pc_out = pc_out;
        hold_btb_pc = btb_pc_out;
        hold_btb_tgt = btb_target_out;
        hold_pred = predicted_taken_out;
        stall = 1'b1;
        tick();
        report_case("Stall holds PC and IF/ID prediction outputs",
                    (current_pc == hold_pc) &&
                    (pc_out == hold_pc_out) &&
                    (btb_pc_out == hold_btb_pc) &&
                    (btb_target_out == hold_btb_tgt) &&
                    (predicted_taken_out == hold_pred));
        stall = 1'b0;

        // 5) Flush clears prediction outputs
        //    Re-prime non-zero prediction outputs first.
        branch_taken = 1'b1;
        branch_target = TARGET_1;
        tick();
        branch_taken = 1'b1;
        branch_target = TARGET_1;
        tick(); // now predicted outputs for 0x180 path should be active

        branch_taken = 1'b0;
        flush = 1'b1;
        tick();
        report_case("Flush clears predicted_taken_out and btb_target_out",
                    (predicted_taken_out == 1'b0) &&
                    (btb_target_out == 32'h0) &&
                    (btb_pc_out == 32'h0));
        flush = 1'b0;

        $display("\n========== FETCH+BTB TEST SUMMARY ==========");
        $display("Total:  %0d", total_tests);
        $display("Passed: %0d", total_passed);
        $display("Failed: %0d", total_failed);
        $display("============================================\n");
        $finish;
    end

endmodule

