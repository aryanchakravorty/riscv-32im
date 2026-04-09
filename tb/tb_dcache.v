`timescale 1ns/1ps

module tb_dcache;
    reg         clk;
    reg         rst;
    reg [31:0]  addr;
    reg [31:0]  write_data;
    reg [3:0]   write_strobe;
    reg         read_en;
    reg         write_en;

    wire [31:0] read_data;
    wire        stall;

    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrobe;
    wire        mem_read;
    wire        mem_write;
    wire [31:0] mem_rdata;
    wire        mem_ready;

    wire [31:0] hit_count;
    wire [31:0] miss_count;

    integer t1_stall_cycles;
    integer t3_stall_cycles;
    integer t4_stall_cycles;
    integer t5_write_stall_cycles;
    integer t2_stall_cycles;
    integer i;

    reg [31:0] rd1;
    reg [31:0] rd1_hit;
    reg [31:0] rd2;
    reg [31:0] rd5;

    reg test1_pass, test2_pass, test3_pass, test4_pass, test5_pass, test6_pass;
    reg [31:0] cache_word_100;
    reg [5:0]  idx_100, idx_200;
    reg [2:0]  off_100;

    dcache uut (
        .clk(clk),
        .rst(rst),
        .addr(addr),
        .write_data(write_data),
        .write_strobe(write_strobe),
        .read_en(read_en),
        .write_en(write_en),
        .read_data(read_data),
        .stall(stall),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wstrobe(mem_wstrobe),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .mem_rdata(mem_rdata),
        .mem_ready(mem_ready),
        .hit_count(hit_count),
        .miss_count(miss_count)
    );

    dmem_model #(
        .LATENCY(10)
    ) u_dmem (
        .clk(clk),
        .addr(mem_addr),
        .wdata(mem_wdata),
        .wstrobe(mem_wstrobe),
        .read_en(mem_read),
        .write_en(mem_write),
        .rdata(mem_rdata),
        .ready(mem_ready)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task do_read;
        input  [31:0] a;
        output [31:0] d;
        output integer stall_cycles;
        integer guard;
        begin
            stall_cycles = 0;
            guard = 0;

            @(negedge clk);
            addr <= a;
            read_en <= 1'b1;
            write_en <= 1'b0;
            write_strobe <= 4'b0000;

            @(posedge clk); #1;
            while (stall) begin
                stall_cycles = stall_cycles + 1;
                guard = guard + 1;
                if (guard > 500) begin
                    $display("[TB][ERROR] do_read timeout at addr=%08h", a);
                    disable do_read;
                end
                @(posedge clk); #1;
            end

            d = read_data;

            @(negedge clk);
            read_en <= 1'b0;
            addr <= 32'h0;
        end
    endtask

    task do_write;
        input [31:0] a;
        input [31:0] d;
        input [3:0]  s;
        output integer stall_cycles;
        integer guard;
        begin
            stall_cycles = 0;
            guard = 0;

            @(negedge clk);
            addr <= a;
            write_data <= d;
            write_strobe <= s;
            write_en <= 1'b1;
            read_en <= 1'b0;

            @(posedge clk); #1;
            while (stall) begin
                stall_cycles = stall_cycles + 1;
                guard = guard + 1;
                if (guard > 500) begin
                    $display("[TB][ERROR] do_write timeout at addr=%08h", a);
                    disable do_write;
                end
                @(posedge clk); #1;
            end

            @(negedge clk);
            write_en <= 1'b0;
            write_data <= 32'h0;
            write_strobe <= 4'b0000;
            addr <= 32'h0;
        end
    endtask

    initial begin
        rst = 1'b0;
        addr = 32'h0;
        write_data = 32'h0;
        write_strobe = 4'b0;
        read_en = 1'b0;
        write_en = 1'b0;

        test1_pass = 1'b0;
        test2_pass = 1'b0;
        test3_pass = 1'b0;
        test4_pass = 1'b0;
        test5_pass = 1'b0;
        test6_pass = 1'b0;

        t1_stall_cycles = 0;
        t3_stall_cycles = 0;
        t4_stall_cycles = 0;
        t5_write_stall_cycles = 0;
        t2_stall_cycles = 0;

        rd1 = 32'h0;
        rd1_hit = 32'h0;
        rd2 = 32'h0;
        rd5 = 32'h0;

        repeat (3) @(posedge clk);
        rst = 1'b1;
        @(posedge clk);

        // Pre-load known memory words.
        for (i = 0; i < 1024; i = i + 1) begin
            u_dmem.mem[i] = 32'h0;
        end
        u_dmem.mem[10'h040] = 32'hAABBCCDD; // addr 0x100
        u_dmem.mem[10'h041] = 32'h11223344; // addr 0x104
        u_dmem.mem[10'h048] = 32'hDEADBEEF; // addr 0x120

        idx_100 = 6'h08; // 0x100[10:5]
        idx_200 = 6'h10; // 0x200[10:5]
        off_100 = 3'h0;  // 0x100[4:2]

        // Test 1 - Read miss then hit.
        do_read(32'h00000100, rd1, t1_stall_cycles);
        do_read(32'h00000100, rd1_hit, i);
        test1_pass = (rd1 == 32'hAABBCCDD) &&
                     (rd1_hit == 32'hAABBCCDD) &&
                     (t1_stall_cycles > 0) &&
                     (i == 0);

        // Test 2 - Adjacent word hit.
        do_read(32'h00000104, rd2, t2_stall_cycles);
        test2_pass = (t2_stall_cycles == 0) && (rd2 == 32'h11223344);

        // Test 3 - Write hit (write-through).
        do_write(32'h00000100, 32'hCAFEBABE, 4'b1111, t3_stall_cycles);
        @(posedge clk); #1;
        cache_word_100 = uut.data_array[idx_100][off_100*32 +: 32];
        test3_pass = (t3_stall_cycles > 0) &&
                     (cache_word_100 == 32'hCAFEBABE) &&
                     (u_dmem.mem[10'h040] == 32'hCAFEBABE);

        // Test 4 - Write miss (no-allocate).
        do_write(32'h00000200, 32'h12345678, 4'b1111, t4_stall_cycles);
        @(posedge clk); #1;
        test4_pass = (t4_stall_cycles > 0) &&
                     (u_dmem.mem[10'h080] == 32'h12345678) &&
                     (uut.valid_array[idx_200] == 1'b0);

        // Test 5 - Read after write.
        do_write(32'h00000100, 32'hDEAD1234, 4'b1111, t5_write_stall_cycles);
        do_read(32'h00000100, rd5, i);
        test5_pass = (rd5 == 32'hDEAD1234);

        // Test 6 - Idle with no enables.
        test6_pass = 1'b1;
        @(negedge clk);
        read_en <= 1'b0;
        write_en <= 1'b0;
        addr <= 32'h0;
        write_data <= 32'h0;
        write_strobe <= 4'b0000;
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk); #1;
            if (stall || mem_read || mem_write) test6_pass = 1'b0;
        end

        $display("DCACHE CHECKPOINT 3:");
        $display("  Test 1 (read miss->hit):     %s  stall_cycles=%0d",
                 test1_pass ? "PASS" : "FAIL", t1_stall_cycles);
        $display("  Test 2 (adjacent hit):       %s  stall=%0d read_data=0x%08h",
                 test2_pass ? "PASS" : "FAIL", t2_stall_cycles, rd2);
        $display("  Test 3 (write-through hit):  %s  %s",
                 test3_pass ? "PASS" : "FAIL",
                 test3_pass ? "cache+mem both updated" : "cache/mem mismatch");
        $display("  Test 4 (write miss bypass):  %s  %s",
                 test4_pass ? "PASS" : "FAIL",
                 test4_pass ? "mem written, cache NOT allocated" : "policy/check failed");
        $display("  Test 5 (read-after-write):   %s  read_data=0x%08h",
                 test5_pass ? "PASS" : "FAIL", rd5);
        $display("  Test 6 (no enables):         %s  %s",
                 test6_pass ? "PASS" : "FAIL",
                 test6_pass ? "no spurious memory access" : "unexpected activity seen");

        $finish;
    end

endmodule
