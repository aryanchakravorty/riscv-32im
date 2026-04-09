`timescale 1ns/1ps

module tb_btb;

    localparam ENTRIES = 16;
    localparam INDEX_BITS = $clog2(ENTRIES);

    localparam [31:0] PC_A      = 32'h00000100;
    localparam [31:0] PC_B      = 32'h00001100; // same index as PC_A, different tag
    localparam [31:0] TARGET_A  = 32'h00000200;
    localparam [31:0] TARGET_B  = 32'h00000300;
    localparam [31:0] TARGET_A2 = 32'h00000444;

    localparam [INDEX_BITS-1:0] IDX_A = PC_A[(INDEX_BITS+1):2];

    reg         clk;
    reg         reset;  // active-low
    reg         stall;

    reg  [31:0] lookup_pc;
    wire        btb_hit;
    wire        btb_predicted_taken;
    wire [31:0] btb_target;

    reg         btb_update_en;
    reg  [31:0] btb_update_pc;
    reg         btb_actual_taken;
    reg  [31:0] btb_actual_target;

    integer total_tests;
    integer total_passed;
    integer total_failed;

    reg prev_hit;
    reg prev_taken;
    reg [31:0] prev_target;
    reg old_pc_miss;
    reg new_pc_hit;

    btb #(
        .ENTRIES(ENTRIES)
    ) DUT (
        .clk(clk),
        .reset(reset),
        .stall(stall),
        .lookup_pc(lookup_pc),
        .btb_hit(btb_hit),
        .btb_predicted_taken(btb_predicted_taken),
        .btb_target(btb_target),
        .btb_update_en(btb_update_en),
        .btb_update_pc(btb_update_pc),
        .btb_actual_taken(btb_actual_taken),
        .btb_actual_target(btb_actual_target)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // #10 period
    end

    task automatic do_lookup;
        input [31:0] pc;
        begin
            lookup_pc = pc;
            btb_update_en = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic do_update;
        input [31:0] pc;
        input [31:0] tgt;
        input        taken;
        begin
            btb_update_pc = pc;
            btb_actual_target = tgt;
            btb_actual_taken = taken;
            btb_update_en = 1'b1;
            @(posedge clk);
            #1;
            btb_update_en = 1'b0;
        end
    endtask

    task automatic report_case;
        input [1023:0] name;
        input         pass_cond;
        begin
            total_tests = total_tests + 1;
            if (pass_cond) begin
                total_passed = total_passed + 1;
                $display("PASS: %0s", name);
            end
            else begin
                total_failed = total_failed + 1;
                $display("FAIL: %0s", name);
            end
        end
    endtask

    initial begin
        reset = 1'b0;
        stall = 1'b0;
        lookup_pc = 32'h0;
        btb_update_en = 1'b0;
        btb_update_pc = 32'h0;
        btb_actual_taken = 1'b0;
        btb_actual_target = 32'h0;
        total_tests = 0;
        total_passed = 0;
        total_failed = 0;

        // Assert reset for 2 cycles
        repeat (2) @(posedge clk);
        reset = 1'b1;
        #1;

        // 1) Cold miss
        do_lookup(PC_A);
        report_case("Cold miss lookup before any update", (btb_hit === 1'b0));

        // 2) Warm hit after update
        do_update(PC_A, TARGET_A, 1'b1);
        do_lookup(PC_A);
        report_case("Warm hit after update (hit/taken/target)",
                    (btb_hit === 1'b1) &&
                    (btb_predicted_taken === 1'b1) &&
                    (btb_target === TARGET_A));

        // 3) Counter saturation on repeated taken updates
        repeat (4) do_update(PC_A, TARGET_A, 1'b1);
        do_lookup(PC_A);
        report_case("Counter saturation at 2'b11 (no wrap)",
                    (DUT.counter_array[IDX_A] === 2'b11) &&
                    (btb_hit === 1'b1) &&
                    (btb_predicted_taken === 1'b1));

        // 4) Counter decrement to strongly not-taken
        repeat (4) do_update(PC_A, TARGET_A, 1'b0);
        do_lookup(PC_A);
        report_case("Counter decrement to 2'b00 and predict NT",
                    (DUT.counter_array[IDX_A] === 2'b00) &&
                    (btb_hit === 1'b1) &&
                    (btb_predicted_taken === 1'b0));

        // 5) Tag collision (same index, different tags)
        do_update(PC_A, TARGET_A, 1'b1);
        do_update(PC_B, TARGET_B, 1'b1); // should replace entry at same index
        do_lookup(PC_A);
        old_pc_miss = (btb_hit === 1'b0);
        do_lookup(PC_B);
        new_pc_hit = (btb_hit === 1'b1) &&
                     (btb_predicted_taken === 1'b1) &&
                     (btb_target === TARGET_B);
        report_case("Tag collision evicts old tag, new tag hits", old_pc_miss && new_pc_hit);

        // 6) Stall freeze output registers during update cycle
        do_lookup(PC_B);
        prev_hit = btb_hit;
        prev_taken = btb_predicted_taken;
        prev_target = btb_target;

        stall = 1'b1;
        lookup_pc = PC_A;
        btb_update_pc = PC_A;
        btb_actual_target = 32'h00000222;
        btb_actual_taken = 1'b1;
        btb_update_en = 1'b1;
        @(posedge clk);
        #1;
        report_case("Stall freezes registered lookup outputs",
                    (btb_hit === prev_hit) &&
                    (btb_predicted_taken === prev_taken) &&
                    (btb_target === prev_target));
        btb_update_en = 1'b0;
        stall = 1'b0;

        // 7) Target update on same PC
        do_update(PC_A, TARGET_A2, 1'b1);
        do_lookup(PC_A);
        report_case("Target update returns new target on hit",
                    (btb_hit === 1'b1) &&
                    (btb_target === TARGET_A2));

        $display("\n========== BTB TEST SUMMARY ==========");
        $display("Total:  %0d", total_tests);
        $display("Passed: %0d", total_passed);
        $display("Failed: %0d", total_failed);
        $display("======================================\n");

        $finish;
    end

endmodule

