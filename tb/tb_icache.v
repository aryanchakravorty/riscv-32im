`timescale 1ns/1ps

module tb_icache;
    reg clk;
    reg rst;
    reg [31:0] pc;
    reg read_en;
    wire [31:0] instruction;
    wire stall;
    
    wire [31:0] mem_addr;
    wire mem_read;
    reg [31:0] mem_data;
    reg mem_ready;

    // Instantiate ICache
    icache uut (
        .clk(clk),
        .rst(rst),
        .pc(pc),
        .read_en(read_en),
        .instruction(instruction),
        .stall(stall),
        .mem_addr(mem_addr),
        .mem_read(mem_read),
        .mem_data(mem_data),
        .mem_ready(mem_ready)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk;

    // Cycle Logger
    integer cycle_count = 0;
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        $display("[Cycle %0d] PC=%h, ReadEn=%b, Stall=%b, Instr=%h, MemRd=%b, MemAddr=%h, MemReady=%b", 
                 cycle_count, pc, read_en, stall, instruction, mem_read, mem_addr, mem_ready);
    end

    // Simulated Memory (Synchronous Mock)
    reg [31:0] mock_mem [0:2047]; 
    integer j;
    reg [1:0] mem_lat_cnt;

    initial begin
        for (j = 0; j < 2048; j = j + 1) begin
            mock_mem[j] = j * 4; 
        end
        mem_lat_cnt = 0;
        mem_ready = 0;
    end

    always @(posedge clk) begin
        if (mem_read) begin
            if (mem_lat_cnt == 2) begin 
                mem_data <= mock_mem[mem_addr[12:2]];
                mem_ready <= 1;
                mem_lat_cnt <= 0;
            end else begin
                mem_ready <= 0;
                mem_lat_cnt <= mem_lat_cnt + 1;
            end
        end else begin
            mem_ready <= 0;
            mem_lat_cnt <= 0;
        end
    end

    integer stall_start;
    
    // Test sequence
    initial begin
        $display("--- Starting Rigorous ICache Verification ---");
        rst = 0;
        pc = 0;
        read_en = 0;
        @(negedge clk);
        rst = 1;
        @(negedge clk);

        // --- TEST 1: COLD MISS ---
        $display("\nTest 1: Cold Miss at 0x000");
        pc = 32'h0000_0000;
        read_en = 1;
        #1;
        if (stall !== 1) $display("FAIL: Expected stall=1 immediately on miss");
        stall_start = cycle_count;
        
        while (stall) @(posedge clk);
        $display("Stall lasted %0d cycles", cycle_count - stall_start);
        
        @(posedge clk); #1;
        if (instruction !== 32'h0000_0000) $display("FAIL: Wrong instruction at 0x00. Got %h", instruction);
        else $display("PASS: Cold Miss resolved correctly.");

        // --- TEST 2: WARM HIT ---
        $display("\nTest 2: Warm Hit at 0x000");
        pc = 32'h0000_0000;
        read_en = 1;
        #1;
        if (stall !== 0) $display("FAIL: Expected stall=0 for warm hit");
        @(posedge clk); #1;
        if (instruction !== 32'h0000_0000) $display("FAIL: Wrong instruction on hit. Got %h", instruction);
        else $display("PASS: Warm Hit handled in 1 cycle.");

        // --- TEST 3: CONFLICT (2-Way Associativity) ---
        $display("\nTest 3: Conflict Accesses (Index 0)");
        $display("Accessing 0x800 (New Tag, Index 0)...");
        pc = 32'h0000_0800;
        #1;
        while (stall) @(posedge clk);
        @(posedge clk); #1;
        
        $display("Verifying 0x000 still in cache (Way 0 vs Way 1)...");
        pc = 32'h0000_0000;
        #1;
        if (stall !== 0) $display("FAIL: 0x000 should NOT be evicted by 0x800 in 2-way cache");
        else $display("PASS: 2-Way Associativity confirmed.");

        // --- TEST 4: SEQUENTIAL ACCESS (Block Hit) ---
        $display("\nTest 4: Sequential Access (Block 0x1000)");
        $display("Accessing 0x1000 (Miss expected)...");
        pc = 32'h0000_1000;
        #1;
        while (stall) @(posedge clk);
        
        $display("Accessing 0x1004 (Sequential, should be HIT)...");
        @(negedge clk);
        pc = 32'h0000_1004;
        #1;
        if (stall !== 0) $display("FAIL: 0x1004 should be a HIT (same block as 0x1000)");
        else $display("PASS: Sequential block hit confirmed.");

        $display("Accessing 0x101C (End of block, should be HIT)...");
        @(negedge clk);
        pc = 32'h0000_101C;
        #1;
        if (stall !== 0) $display("FAIL: 0x101C should be a HIT");
        else $display("PASS: Full block coverage confirmed.");

        $display("\n--- All Rigorous Tests Completed ---");
        $finish;
    end

endmodule
