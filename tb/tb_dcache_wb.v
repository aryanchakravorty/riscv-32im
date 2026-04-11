`timescale 1ns/1ps

module tb_dcache_wb;
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
    wire [31:0] writeback_count;

    localparam [31:0] ADDR_BASE      = 32'h00000100; // tag=0x0,   index=8
    localparam [31:0] ADDR_CONFLICT1 = 32'h00100100; // tag=0x100, index=8
    localparam [31:0] ADDR_CONFLICT2 = 32'h00200100; // tag=0x200, index=8
    localparam [31:0] ADDR_TIMING    = 32'h00000300; // tag=0x0,   index=24
    localparam [31:0] DATA_TIMING    = 32'hCAFED00D;
    localparam integer EXPECTED_MISS_STALL = 18;

    integer i;
    integer t_step1;
    integer t_step2;
    integer t_step3;
    integer t_step4a;
    integer t_step4b;
    integer t_step5w;
    integer t_step5r;
    integer t_step6w0;
    integer t_step6w1;
    integer t_step6w2;
    integer t_step6e;
    integer t_miss_stall;

    reg [31:0] rd1;
    reg [31:0] rd3;
    reg [31:0] rd5;
    reg [31:0] rd_tmp;
    reg [31:0] rd_miss_done;
    reg [31:0] rd_next_hit;
    reg [31:0] wb_before;
    reg [31:0] wb_after_writes;

    reg test0_pass;
    reg test1_pass;
    reg test2_pass;
    reg test3_pass;
    reg test4_pass;
    reg test5_pass;
    reg test6_pass;
    reg next_cycle_hit_ok;

    dcache u_dcache (
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
        .miss_count(miss_count),
        .writeback_count(writeback_count)
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
            write_data <= 32'h0;
            write_strobe <= 4'b0000;

            @(posedge clk); #1;
            while (stall) begin
                stall_cycles = stall_cycles + 1;
                guard = guard + 1;
                if (guard > 2000) begin
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
                if (guard > 2000) begin
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

    task measure_miss_then_next_hit;
        input  [31:0] a;
        input  [31:0] expected_data;
        output integer stall_cycles;
        output [31:0] data_on_deassert;
        output [31:0] data_next_cycle;
        output reg immediate_hit_ok;
        integer guard;
        begin
            stall_cycles = 0;
            data_on_deassert = 32'h0;
            data_next_cycle = 32'h0;
            immediate_hit_ok = 1'b0;
            guard = 0;

            @(negedge clk);
            addr <= a;
            read_en <= 1'b1;
            write_en <= 1'b0;
            write_data <= 32'h0;
            write_strobe <= 4'b0000;

            @(posedge clk); #1;
            while (!stall) begin
                guard = guard + 1;
                if (guard > 2000) begin
                    $display("[TB][ERROR] measure_miss_then_next_hit did not see stall at addr=%08h", a);
                    disable measure_miss_then_next_hit;
                end
                @(posedge clk); #1;
            end

            while (stall) begin
                stall_cycles = stall_cycles + 1;
                guard = guard + 1;
                if (guard > 4000) begin
                    $display("[TB][ERROR] measure_miss_then_next_hit timeout at addr=%08h", a);
                    disable measure_miss_then_next_hit;
                end
                @(posedge clk); #1;
            end

            data_on_deassert = read_data;

            @(posedge clk); #1;
            data_next_cycle = read_data;
            immediate_hit_ok = (stall == 1'b0) && (data_next_cycle == expected_data);

            @(negedge clk);
            read_en <= 1'b0;
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

        test0_pass = 1'b0;
        test1_pass = 1'b0;
        test2_pass = 1'b0;
        test3_pass = 1'b0;
        test4_pass = 1'b0;
        test5_pass = 1'b0;
        test6_pass = 1'b0;

        repeat (3) @(posedge clk);
        rst = 1'b1;
        @(posedge clk);

        for (i = 0; i < 1024; i = i + 1) begin
            u_dmem.mem[i] = 32'h00000000;
        end
        u_dmem.mem[10'd64] = 32'hAAAAAAAA; // 0x100 / 4
        u_dmem.mem[10'd192] = DATA_TIMING; // 0x300 / 4

        // Timing check - no extra post-miss stall cycle after suppress_once removal.
        measure_miss_then_next_hit(ADDR_TIMING, DATA_TIMING, t_miss_stall, rd_miss_done, rd_next_hit, next_cycle_hit_ok);
        test0_pass = (t_miss_stall == EXPECTED_MISS_STALL) &&
                     (rd_miss_done == DATA_TIMING) &&
                     next_cycle_hit_ok;
        $display("Measured miss stall cycles = %0d (expected in this TB: %0d)", t_miss_stall, EXPECTED_MISS_STALL);
        $display("Test 0 (no extra post-miss stall cycle): %s", test0_pass ? "PASS" : "FAIL");

        // Test 1 - Write hit does NOT write memory (write-back).
        do_read(ADDR_BASE, rd1, t_step1); // fill, dirty=0
        do_write(ADDR_BASE, 32'hDEADDEAD, 4'b1111, t_step2); // write hit
        @(posedge clk); #1;
        test1_pass = (rd1 == 32'hAAAAAAAA) &&
                     (t_step1 > 0) &&
                     (t_step2 == 0) &&
                     (u_dmem.mem[10'd64] == 32'hAAAAAAAA) &&
                     (writeback_count == 32'd0);
        $display("Test 1 (write hit no-memory-write): %s", test1_pass ? "PASS" : "FAIL");

        // Test 2 - Dirty eviction writes to memory.
        do_read(ADDR_CONFLICT1, rd_tmp, t_step3); // conflict at same index, different tag
        @(posedge clk); #1;
        test2_pass = (t_step3 > 0) &&
                     (writeback_count == 32'd1) &&
                     (u_dmem.mem[10'd64] == 32'hDEADDEAD);
        $display("Test 2 (dirty eviction writes memory): %s", test2_pass ? "PASS" : "FAIL");

        // Test 3 - Read after eviction returns the evicted+refilled value.
        do_read(ADDR_BASE, rd3, t_step4a);
        test3_pass = (rd3 == 32'hDEADDEAD);
        $display("Test 3 (read evicted+refilled line): %s", test3_pass ? "PASS" : "FAIL");

        // Test 4 - Clean eviction does NOT write memory.
        do_read(ADDR_BASE, rd_tmp, t_step4a); // ensure current line is clean
        wb_before = writeback_count;
        do_read(ADDR_CONFLICT1, rd_tmp, t_step4b); // evict clean line
        @(posedge clk); #1;
        test4_pass = (t_step4b > 0) &&
                     (writeback_count == wb_before) &&
                     (writeback_count == 32'd1) &&
                     (u_dmem.mem[10'd64] == 32'hDEADDEAD);
        $display("Test 4 (clean eviction no writeback): %s", test4_pass ? "PASS" : "FAIL");

        // Test 5 - Write-allocate on write miss.
        do_write(ADDR_BASE, 32'h12345678, 4'b1111, t_step5w); // miss -> fill + pending write
        do_read(ADDR_BASE, rd5, t_step5r); // should be immediate hit
        test5_pass = (t_step5w > 0) &&
                     (t_step5r == 0) &&
                     (rd5 == 32'h12345678);
        $display("Test 5 (write-allocate): %s", test5_pass ? "PASS" : "FAIL");

        // Test 6 - Multiple writes, single eviction.
        wb_before = writeback_count;
        do_write(ADDR_BASE,          32'h11111111, 4'b1111, t_step6w0);
        do_write(ADDR_BASE + 32'h4,  32'h22222222, 4'b1111, t_step6w1);
        do_write(ADDR_BASE + 32'h8,  32'h33333333, 4'b1111, t_step6w2);
        wb_after_writes = writeback_count;
        do_read(ADDR_CONFLICT2, rd_tmp, t_step6e); // one dirty eviction
        @(posedge clk); #1;
        test6_pass = (t_step6w0 == 0) &&
                     (t_step6w1 == 0) &&
                     (t_step6w2 == 0) &&
                     (wb_after_writes == wb_before) &&
                     (writeback_count == (wb_before + 1)) &&
                     (u_dmem.mem[10'd64] == 32'h11111111) &&
                     (u_dmem.mem[10'd65] == 32'h22222222) &&
                     (u_dmem.mem[10'd66] == 32'h33333333);
        $display("Test 6 (multiple writes -> one eviction): %s", test6_pass ? "PASS" : "FAIL");

        $display("writeback_count = %0d (expected: 2)", u_dcache.writeback_count);
        $display("hit_count = %0d", u_dcache.hit_count);
        $display("miss_count = %0d", u_dcache.miss_count);
        $finish;
    end

endmodule
