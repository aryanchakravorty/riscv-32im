`timescale 1ns / 1ps

module tb_bench_matmul;

    reg clk;
    reg reset;
    wire exception;
    wire [31:0] pc_out;
    wire [31:0] alu_result_dbg;

    integer i;
    integer set_idx;
    integer word_idx;
    integer cycle_count;
    integer nop_window;
    integer fd;

    pipe DUT (
        .clk(clk),
        .reset(reset),
        .stall(1'b0),
        .exception(exception),
        .pc_out(pc_out),
        .alu_result_dbg(alu_result_dbg)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task load_bench_memories;
        begin
            for (i = 0; i < 1024; i = i + 1) begin
                DUT.u_imem.mem[i] = 32'h0;
                DUT.u_dmem.mem[i] = 32'h0;
            end

            fd = $fopen("bench_matmul.hex", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("bench_matmul.hex", DUT.u_imem.mem);
            end else begin
                fd = $fopen("../../../../bench_matmul.hex", "r");
                if (fd != 0) begin
                    $fclose(fd);
                    $readmemh("../../../../bench_matmul.hex", DUT.u_imem.mem);
                end else begin
                    fd = $fopen("..\\..\\..\\..\\bench_matmul.hex", "r");
                    if (fd != 0) begin
                        $fclose(fd);
                        $readmemh("..\\..\\..\\..\\bench_matmul.hex", DUT.u_imem.mem);
                    end else begin
                        fd = $fopen("../../../../../bench_matmul.hex", "r");
                        if (fd != 0) begin
                            $fclose(fd);
                            $readmemh("../../../../../bench_matmul.hex", DUT.u_imem.mem);
                        end else begin
                            $display("ERROR: bench_matmul.hex not found.");
                        end
                    end
                end
            end

            fd = $fopen("dmem_matmul.hex", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("dmem_matmul.hex", DUT.u_dmem.mem);
            end else begin
                fd = $fopen("../../../../dmem_matmul.hex", "r");
                if (fd != 0) begin
                    $fclose(fd);
                    $readmemh("../../../../dmem_matmul.hex", DUT.u_dmem.mem);
                end else begin
                    fd = $fopen("..\\..\\..\\..\\dmem_matmul.hex", "r");
                    if (fd != 0) begin
                        $fclose(fd);
                        $readmemh("..\\..\\..\\..\\dmem_matmul.hex", DUT.u_dmem.mem);
                    end else begin
                        fd = $fopen("../../../../../dmem_matmul.hex", "r");
                        if (fd != 0) begin
                            $fclose(fd);
                            $readmemh("../../../../../dmem_matmul.hex", DUT.u_dmem.mem);
                        end else begin
                            $display("ERROR: dmem_matmul.hex not found.");
                        end
                    end
                end
            end

            if ((DUT.u_dmem.mem['h200] !== 32'h0) && (DUT.u_dmem.mem['h080] === 32'h0)) begin
                for (i = 0; i < 16; i = i + 1) begin
                    DUT.u_dmem.mem['h080 + i] = DUT.u_dmem.mem['h200 + i];
                    DUT.u_dmem.mem['h090 + i] = DUT.u_dmem.mem['h240 + i];
                    DUT.u_dmem.mem['h0A0 + i] = DUT.u_dmem.mem['h280 + i];
                end
            end
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
        reset = 1'b0;
        #1;
        load_bench_memories();
        #99;
        reset = 1'b1;

        cycle_count = 0;
        nop_window  = 0;

        while ((cycle_count < 5000) && (nop_window < 8)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
            if ((DUT.pc_out >= 32'h00000088) && (DUT.pc_out <= 32'h00000094))
                nop_window = nop_window + 1;
            else
                nop_window = 0;
        end

        if (cycle_count >= 5000) begin
            $display("TIMEOUT: 5000 cycles reached before NOP sled detection.");
        end else begin
            repeat (10) @(posedge clk);
        end

        flush_dcache_to_dmem_model();

        $display("C[0][0] = %0d (expect 1)",  DUT.u_dmem.mem[32'h280/4]);
        $display("C[1][1] = %0d (expect 6)",  DUT.u_dmem.mem[32'h294/4]);
        $display("C[3][3] = %0d (expect 16)", DUT.u_dmem.mem[32'h2BC/4]);

        $display("================================================");
        $display("  PIPELINE PERFORMANCE REPORT");
        $display("================================================");
        $display("  Total cycles:        %0d", DUT.u_perf.total_cycles);
        $display("  Instructions retired:%0d", DUT.u_perf.instrs_retired);
        $display("  IPC:                 %0d.%02d",
                 (DUT.u_perf.total_cycles != 0) ? (DUT.u_perf.instrs_retired / DUT.u_perf.total_cycles) : 0,
                 (DUT.u_perf.total_cycles != 0) ? ((DUT.u_perf.instrs_retired * 100 / DUT.u_perf.total_cycles) % 100) : 0);
        $display("--- Stall Breakdown (cycles) ---");
        $display("  I-Cache miss stalls: %0d (%0d%%)", DUT.perf_icstall,
                 (DUT.u_perf.total_cycles != 0) ? (100*DUT.perf_icstall/DUT.u_perf.total_cycles) : 0);
        $display("  D-Cache miss stalls: %0d (%0d%%)", DUT.perf_dcstall,
                 (DUT.u_perf.total_cycles != 0) ? (100*DUT.perf_dcstall/DUT.u_perf.total_cycles) : 0);
        $display("  Load-use stalls:     %0d (%0d%%)", DUT.perf_luuse,
                 (DUT.u_perf.total_cycles != 0) ? (100*DUT.perf_luuse/DUT.u_perf.total_cycles) : 0);
        $display("  Division stalls:     %0d (%0d%%)", DUT.perf_divstall,
                 (DUT.u_perf.total_cycles != 0) ? (100*DUT.perf_divstall/DUT.u_perf.total_cycles) : 0);
        $display("--- Cache Performance ---");
        $display("  I-Cache hit rate:    %0d%% (%0d hits, %0d misses)",
                 ((DUT.perf_ihits + DUT.perf_imisses) != 0) ? (100*DUT.perf_ihits/(DUT.perf_ihits + DUT.perf_imisses)) : 0,
                 DUT.perf_ihits, DUT.perf_imisses);
        $display("  D-Cache hit rate:    %0d%% (%0d hits, %0d misses)",
                 ((DUT.perf_dhits + DUT.perf_dmisses) != 0) ? (100*DUT.perf_dhits/(DUT.perf_dhits + DUT.perf_dmisses)) : 0,
                 DUT.perf_dhits, DUT.perf_dmisses);
        $display("  D-Cache writebacks:  %0d", DUT.perf_dwb);
        $display("--- Branch Prediction ---");
        $display("  Branches taken:      %0d", DUT.perf_br_taken);
        $display("  Mispredictions:      %0d", DUT.perf_mispredict);
        $display("  BTB accuracy:        %0d%%",
                 (DUT.perf_br_taken > 0) ?
                 (100*(DUT.perf_br_taken - DUT.perf_mispredict)/DUT.perf_br_taken)
                 : 100);
        $display("================================================");

        $finish;
    end

endmodule
