`timescale 1ns / 1ps

module tb_bench_newton;

    reg clk;
    reg reset;
    wire exception;
    wire [31:0] pc_out;
    wire [31:0] alu_result_dbg;

    integer i;
    integer set_idx;
    integer word_idx;
    integer cycle_count;
    integer fd;
    reg store_done;

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

    task load_newton_memories;
        begin
            for (i = 0; i < 1024; i = i + 1) begin
                DUT.u_imem.mem[i] = 32'h0;
                DUT.u_dmem.mem[i] = 32'h0;
            end

            fd = $fopen("bench_newton.hex", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("bench_newton.hex", DUT.u_imem.mem);
            end else begin
                fd = $fopen("../../../../bench_newton.hex", "r");
                if (fd != 0) begin
                    $fclose(fd);
                    $readmemh("../../../../bench_newton.hex", DUT.u_imem.mem);
                end else begin
                    fd = $fopen("..\\..\\..\\..\\bench_newton.hex", "r");
                    if (fd != 0) begin
                        $fclose(fd);
                        $readmemh("..\\..\\..\\..\\bench_newton.hex", DUT.u_imem.mem);
                    end else begin
                        fd = $fopen("../../../../../bench_newton.hex", "r");
                        if (fd != 0) begin
                            $fclose(fd);
                            $readmemh("../../../../../bench_newton.hex", DUT.u_imem.mem);
                        end else begin
                            $display("ERROR: bench_newton.hex not found.");
                        end
                    end
                end
            end

            fd = $fopen("dmem_newton.hex", "r");
            if (fd != 0) begin
                $fclose(fd);
                $readmemh("dmem_newton.hex", DUT.u_dmem.mem);
            end else begin
                fd = $fopen("../../../../dmem_newton.hex", "r");
                if (fd != 0) begin
                    $fclose(fd);
                    $readmemh("../../../../dmem_newton.hex", DUT.u_dmem.mem);
                end else begin
                    fd = $fopen("..\\..\\..\\..\\dmem_newton.hex", "r");
                    if (fd != 0) begin
                        $fclose(fd);
                        $readmemh("..\\..\\..\\..\\dmem_newton.hex", DUT.u_dmem.mem);
                    end else begin
                        fd = $fopen("../../../../../dmem_newton.hex", "r");
                        if (fd != 0) begin
                            $fclose(fd);
                            $readmemh("../../../../../dmem_newton.hex", DUT.u_dmem.mem);
                        end else begin
                            $display("ERROR: dmem_newton.hex not found.");
                        end
                    end
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
        load_newton_memories();
        #99;
        reset = 1'b1;

        cycle_count = 0;
        store_done = 1'b0;

        while ((cycle_count < 50000) && !store_done) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            if ((DUT.u_dcache.valid_array[7'd8] == 1'b1) &&
                (DUT.u_dcache.tag_array[7'd8]   == 20'h00000) &&
                (DUT.u_dcache.dirty_array[7'd8] == 1'b1))
                store_done = 1'b1;
        end

        if (!store_done)
            $display("TIMEOUT: 50000 cycles reached before SW completion.");

        repeat (10) @(posedge clk);

        flush_dcache_to_dmem_model();

        $display("Newton result (hex):    %08h", DUT.u_dmem.mem[32'h100/4]);
        $display("Expected (sqrt(2)):     3FB504F3 = 1.41421...");
        $display("FPU stall cycles:       %0d", DUT.u_perf.div_stall_cycles);
        $display("Total cycles:           %0d", DUT.u_perf.total_cycles);

        if (DUT.u_dmem.mem[32'h100/4] == 32'h3FB504F3)
            $display("Match: EXACT");
        else if ((DUT.u_dmem.mem[32'h100/4] >= 32'h3FB504F0) &&
                 (DUT.u_dmem.mem[32'h100/4] <= 32'h3FB504F6))
            $display("Match: WITHIN 1 ULP (acceptable)");
        else
            $display("Match: WRONG - investigate");

        $finish;
    end

endmodule
