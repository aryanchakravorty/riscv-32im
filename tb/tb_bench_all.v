`timescale 1ns/1ps

module tb_bench_all;

    reg clk, reset;
    reg tb_stall;
    wire exception;
    wire [31:0] pc_out;
    wire [31:0] alu_result_dbg;

    pipe DUT (
        .clk(clk),
        .reset(reset),
        .stall(tb_stall),
        .exception(exception),
        .pc_out(pc_out),
        .alu_result_dbg(alu_result_dbg)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer bench_cycles [0:2];
    integer bench_instrs [0:2];
    integer bench_dcstall [0:2];
    integer bench_divstall [0:2];
    integer bench_dhits [0:2];
    integer bench_dmisses [0:2];

    integer stuck_count;
    reg [31:0] prev_pc;
    integer set_idx;
    integer word_idx;
    integer relocate_i;
    integer ic_set_idx;

    task do_reset;
        begin
            tb_stall = 1;
            reset = 0;
            for (ic_set_idx = 0; ic_set_idx < 64; ic_set_idx = ic_set_idx + 1) begin
                DUT.u_icache.valid_array0[ic_set_idx] = 1'b0;
                DUT.u_icache.valid_array1[ic_set_idx] = 1'b0;
                DUT.u_icache.lru[ic_set_idx] = 1'b0;
            end
            repeat (20) @(posedge clk);
            @(negedge clk);
            reset = 1;
            repeat (5) @(posedge clk);
            tb_stall = 0;
        end
    endtask

    integer halt_detected;
    task wait_for_halt;
        input integer timeout_cycles;
        integer cycle_count;
        begin
            stuck_count = 0;
            prev_pc = 32'hFFFFFFFF;
            cycle_count = 0;
            halt_detected = 0;
            while (cycle_count < timeout_cycles && !halt_detected) begin
                @(posedge clk);
                cycle_count = cycle_count + 1;
                if ((pc_out == prev_pc) &&
                    !DUT.icache_stall &&
                    !DUT.dcache_stall &&
                    !DUT.ex_stall_out) begin
                    stuck_count = stuck_count + 1;
                    if (stuck_count >= 50) begin
                        halt_detected = 1;
                    end
                end else if (pc_out != prev_pc) begin
                    stuck_count = 0;
                    prev_pc = pc_out;
                end else begin
                    stuck_count = 0;
                end
            end
            if (!halt_detected)
                $display("  WARNING: timed out after %0d cycles", timeout_cycles);
        end
    endtask

    task capture_perf;
        input integer i;
        begin
            @(negedge clk);
            bench_cycles[i] = DUT.u_perf.total_cycles;
            bench_instrs[i] = DUT.u_perf.instrs_retired;
            bench_dcstall[i] = DUT.u_perf.dcache_stall_cycles;
            bench_divstall[i] = DUT.u_perf.div_stall_cycles;
            bench_dhits[i] = DUT.u_perf.dcache_hits;
            bench_dmisses[i] = DUT.u_perf.dcache_misses;
        end
    endtask

    task flush_dcache_to_dmem_model;
        reg [31:0] wb_addr_base;
        begin
            for (set_idx = 0; set_idx < 128; set_idx = set_idx + 1) begin
                if (DUT.u_dcache.valid_array[set_idx] && DUT.u_dcache.dirty_array[set_idx]) begin
                    wb_addr_base = {DUT.u_dcache.tag_array[set_idx], set_idx[6:0], 5'b00000};
                    for (word_idx = 0; word_idx < 8; word_idx = word_idx + 1) begin
                        DUT.u_dmem.mem[(wb_addr_base[11:2] + word_idx) & 10'h3FF] =
                            DUT.u_dcache.data_array[set_idx][word_idx*32 +: 32];
                    end
                end
            end
        end
    endtask

    initial begin
        tb_stall = 0;
        $display("Starting benchmarks...");

        do_reset;
        $readmemh("bench_matmul.hex", DUT.u_imem.mem);
        $readmemh("dmem_matmul.hex", DUT.u_dmem.mem);
        if ((DUT.u_dmem.mem['h200] !== 32'h0) && (DUT.u_dmem.mem['h080] === 32'h0)) begin
            for (relocate_i = 0; relocate_i < 16; relocate_i = relocate_i + 1) begin
                DUT.u_dmem.mem['h080 + relocate_i] = DUT.u_dmem.mem['h200 + relocate_i];
                DUT.u_dmem.mem['h090 + relocate_i] = DUT.u_dmem.mem['h240 + relocate_i];
                DUT.u_dmem.mem['h0A0 + relocate_i] = DUT.u_dmem.mem['h280 + relocate_i];
            end
        end
        do_reset;
        $display("Running MatMul...");
        wait_for_halt(5000);
        flush_dcache_to_dmem_model();
        $display("  MatMul C[0][0] = %0d (expect 1)", DUT.u_dmem.mem[32'h280/4]);
        $display("  MatMul C[3][3] = %0d (expect 16)", DUT.u_dmem.mem[32'h2BC/4]);
        capture_perf(0);

        do_reset;
        $readmemh("bench_newton.hex", DUT.u_imem.mem);
        $readmemh("dmem_newton.hex", DUT.u_dmem.mem);
        do_reset;
        $display("Running Newton-Raphson...");
        wait_for_halt(50000);
        flush_dcache_to_dmem_model();
        $display("  Newton halt detected at cycle %0d", DUT.u_perf.total_cycles);
        $display("  FPU/DIV stall cycles: %0d", DUT.u_perf.div_stall_cycles);
        $display("  Newton result = 0x%08h (expect 0x3FB504F3 = sqrt(2))",
                 DUT.u_dmem.mem[32'h100/4]);
        capture_perf(1);

        do_reset;
        $readmemh("bench_strided.hex", DUT.u_imem.mem);
        $readmemh("dmem_strided.hex", DUT.u_dmem.mem);
        do_reset;
        $display("Running Strided...");
        wait_for_halt(5000);
        flush_dcache_to_dmem_model();
        $display("  Strided result = %0d (expect 528)", DUT.u_dmem.mem[32'h400/4]);
        capture_perf(2);

        $display("");
        $display("+----------------------------------------------------------+");
        $display("|         RV32IM PIPELINE BENCHMARK RESULTS                |");
        $display("+-------------------+--------+------+---------+------------+");
        $display("| Benchmark         | Cycles |  IPC | D$ Hit%% | D$ Stall%% |");
        $display("+-------------------+--------+------+---------+------------+");

        begin : print_results
            integer i;
            integer ipc_int, ipc_frac;
            integer dhit_pct, dstall_pct;
            reg [63:0] total_daccess;
            for (i = 0; i < 3; i = i + 1) begin
                ipc_int = (bench_cycles[i] > 0) ? (bench_instrs[i] / bench_cycles[i]) : 0;
                ipc_frac = (bench_cycles[i] > 0) ? ((bench_instrs[i] * 100 / bench_cycles[i]) % 100) : 0;
                total_daccess = bench_dhits[i] + bench_dmisses[i];
                dhit_pct = (total_daccess > 0) ? (bench_dhits[i] * 100 / total_daccess) : 0;
                dstall_pct = (bench_cycles[i] > 0) ? (bench_dcstall[i] * 100 / bench_cycles[i]) : 0;

                case (i)
                    0: $display("| MatMul (4x4 int) | %6d | %0d.%02d |     %3d%% |       %3d%% |",
                                bench_cycles[i], ipc_int, ipc_frac, dhit_pct, dstall_pct);
                    1: $display("| Newton (sqrt(2)) | %6d | %0d.%02d |     %3d%% |       %3d%% |",
                                bench_cycles[i], ipc_int, ipc_frac, dhit_pct, dstall_pct);
                    2: $display("| Strided (32B)    | %6d | %0d.%02d |     %3d%% |       %3d%% |",
                                bench_cycles[i], ipc_int, ipc_frac, dhit_pct, dstall_pct);
                endcase
            end
        end
        $display("+-------------------+--------+------+---------+------------+");

        $display("");
        $display("FPU div stall cycles (Newton): %0d", bench_divstall[1]);
        $finish;
    end

endmodule
