`timescale 1ns / 1ps

module tb_newton_c;

    localparam integer IMEM_WORDS = 1024;
    localparam integer IMEM_BYTES = 8192;

    reg clk;
    reg reset;
    wire exception;
    wire [31:0] pc_out;
    wire [31:0] alu_result_dbg;

    integer i;
    integer fd;
    integer set_idx;
    integer word_idx;
    integer cycle_count;
    integer check_cycle;
    integer error_lsb;
    reg [31:0] probe_pc;
    reg [7:0] imem_bytes [0:IMEM_BYTES-1];
    reg imem_loaded;
    reg stable_probe;
    reg stuck;

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

    task pack_imem_bytes_to_words;
        begin
            for (i = 0; i < IMEM_WORDS; i = i + 1) begin
                DUT.u_imem.mem[i] = {
                    imem_bytes[i*4 + 3],
                    imem_bytes[i*4 + 2],
                    imem_bytes[i*4 + 1],
                    imem_bytes[i*4 + 0]
                };
            end
        end
    endtask

    task load_newton_c_memories;
        begin
            for (i = 0; i < IMEM_WORDS; i = i + 1) begin
                DUT.u_imem.mem[i] = 32'h0;
                DUT.u_dmem.mem[i] = 32'h0;
            end

            for (i = 0; i < IMEM_BYTES; i = i + 1)
                imem_bytes[i] = 8'h00;

            imem_loaded = 1'b0;
            fd = $fopen("newton_c.hex", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("newton_c.hex", imem_bytes);
                imem_loaded = 1'b1;
            end else begin
                fd = $fopen("../../../../newton_c.hex", "r");
                if (fd != 0) begin
                    $fclose(fd);
                    $readmemh("../../../../newton_c.hex", imem_bytes);
                    imem_loaded = 1'b1;
                end else begin
                    fd = $fopen("..\\..\\..\\..\\newton_c.hex", "r");
                    if (fd != 0) begin
                        $fclose(fd);
                        $readmemh("..\\..\\..\\..\\newton_c.hex", imem_bytes);
                        imem_loaded = 1'b1;
                    end else begin
                        fd = $fopen("../../../../../newton_c.hex", "r");
                        if (fd != 0) begin
                            $fclose(fd);
                            $readmemh("../../../../../newton_c.hex", imem_bytes);
                            imem_loaded = 1'b1;
                        end else begin
                            $display("ERROR: newton_c.hex not found.");
                        end
                    end
                end
            end

            if (imem_loaded)
                pack_imem_bytes_to_words();
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

    task print_perf_report;
        begin
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
        end
    endtask

    initial begin
        reset = 1'b0;
        #1;
        load_newton_c_memories();
        #99;
        reset = 1'b1;

        cycle_count = 0;
        stuck = 1'b0;
        probe_pc = 32'h0;
        stable_probe = 1'b0;

        while ((cycle_count < 50000) && !stuck) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            if ((cycle_count % 1000) == 0) begin
                probe_pc = DUT.pc_out;
                stable_probe = 1'b1;
                for (check_cycle = 0; (check_cycle < 100) && (cycle_count < 50000); check_cycle = check_cycle + 1) begin
                    @(posedge clk);
                    cycle_count = cycle_count + 1;
                    if (DUT.pc_out != probe_pc)
                        stable_probe = 1'b0;
                    if (DUT.ex_stall_out)
                        stable_probe = 1'b0;
                end
                if ((check_cycle < 100) || !stable_probe)
                    stable_probe = 1'b0;
                if (stable_probe)
                    stuck = 1'b1;
            end
        end

        if (!stuck)
            $display("TIMEOUT: 50000 cycles reached without PC stuck-loop detection.");

        repeat (10) @(posedge clk);

        flush_dcache_to_dmem_model();

        error_lsb = DUT.u_dmem.mem[32'h100/4] - 32'd92681;
        if (error_lsb < 0)
            error_lsb = -error_lsb;

        $display("C Newton-Raphson result: %0d (hex: %08h)", DUT.u_dmem.mem[32'h100/4], DUT.u_dmem.mem[32'h100/4]);
        $display("Expected: ~92681 (0x16A09)");
        $display("Error: %0d LSBs", error_lsb);

        print_perf_report();

        $finish;
    end

endmodule
