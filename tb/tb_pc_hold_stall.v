`timescale 1ns / 1ps

module tb_pc_hold_stall;
    reg clk;
    reg reset;
    wire exception;
    wire [31:0] pc_out;

    integer cycle;
    integer errors;
    integer checks;
    integer stall_cycles;
    reg in_stall;
    reg stall_seen;
    reg [31:0] stall_pc;
    reg [31:0] stall_instruction;

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

    initial begin
        reset = 1'b0;
        cycle = 0;
        errors = 0;
        checks = 0;
        stall_cycles = 0;
        in_stall = 1'b0;
        stall_seen = 1'b0;
        stall_pc = 32'h0;
        stall_instruction = 32'h0;
        #100;
        reset = 1'b1;
    end

    task automatic fail_check;
        input [255:0] msg;
        begin
            errors = errors + 1;
            $display("  [FAIL] %s", msg);
        end
    endtask

    task automatic finish_and_report;
        begin
            $display("\n========== PC HOLD DURING STALL CHECK ==========");
            $display("  Stall seen:     %0d", stall_seen);
            $display("  Stall cycles:   %0d", stall_cycles);
            $display("  Hold checks:    %0d", checks);
            $display("  Error count:    %0d", errors);
            if (errors == 0) begin
                $display("  RESULT: PASS");
            end else begin
                $display("  RESULT: FAIL");
            end
            $display("===============================================\n");
            $finish;
        end
    endtask

    // Sample at negedge so all posedge state updates are settled.
    always @(negedge clk) begin
        if (!reset) begin
            cycle <= 0;
        end else begin
            cycle <= cycle + 1;

            if (!in_stall && DUT.icache_stall) begin
                stall_seen <= 1'b1;
                in_stall <= 1'b1;
                stall_cycles <= 1;
                stall_pc <= DUT.u_fetch.current_pc;
                stall_instruction <= DUT.if_instruction;
                $display("[INFO] Stall start @ cycle %0d: pc=%08h, if_instruction=%08h",
                         cycle, DUT.u_fetch.current_pc, DUT.if_instruction);

            end else if (in_stall && DUT.icache_stall) begin
                stall_cycles <= stall_cycles + 1;
                checks <= checks + 2;

                if (DUT.u_fetch.current_pc !== stall_pc) begin
                    fail_check("PC changed while icache_stall=1");
                end
                if (DUT.if_instruction !== stall_instruction) begin
                    fail_check("IF/ID instruction changed while icache_stall=1");
                end

            end else if (in_stall && !DUT.icache_stall) begin
                checks <= checks + 1;
                if (DUT.u_fetch.current_pc !== stall_pc) begin
                    fail_check("PC changed on stall deassert cycle");
                end

                $display("[INFO] Stall end   @ cycle %0d: pc=%08h (expected %08h)",
                         cycle, DUT.u_fetch.current_pc, stall_pc);
                finish_and_report();
            end

            if (cycle > 600) begin
                if (!stall_seen) begin
                    fail_check("No icache stall observed");
                end else if (in_stall) begin
                    fail_check("Stall did not deassert before timeout");
                end
                finish_and_report();
            end
        end
    end

endmodule
