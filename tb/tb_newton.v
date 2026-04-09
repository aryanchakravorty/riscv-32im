`timescale 1ns / 1ps

module tb_newton;

    reg clk;
    reg reset;
    wire exception;
    wire [31:0] pc_out;
    wire [31:0] alu_result_dbg;

    integer i;
    integer cycles;
    reg [31:0] result_bits;

    localparam [31:0] NOP = 32'h00000013;
    localparam [31:0] SQRT2_LOW  = 32'h3FB3BCD3; // 1.4042
    localparam [31:0] SQRT2_HIGH = 32'h3FB64C30; // 1.4242

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

    initial begin
        reset = 1'b0;

        // Clear instruction memory first so old program words do not leak in.
        for (i = 0; i < 1024; i = i + 1)
            DUT.u_imem.mem[i] = NOP;

        // Program computes one NR iteration:
        // x_{n+1} = 0.5 * x_n * (3.0 - a*x_n*x_n), a=2.0, x0=0.5
        $readmemh("newton_imem.hex", DUT.u_imem.mem);

        #100;
        reset = 1'b1;

        cycles = 0;
        while ((DUT.regs[31] !== 32'h00000001) && (cycles < 2000)) begin
            @(negedge clk);
            cycles = cycles + 1;
        end
        repeat (8) @(negedge clk);

        result_bits = DUT.regs[10];

        $display("Newton result bits (x10) = 0x%08h", result_bits);
        $display("Expected sqrt(2.0) bit-range for +/-0.01: [0x%08h, 0x%08h]", SQRT2_LOW, SQRT2_HIGH);

        if ((cycles < 2000) && (result_bits >= SQRT2_LOW) && (result_bits <= SQRT2_HIGH)) begin
            $display("PASS");
        end else begin
            $display("FAIL");
        end

        $finish;
    end

endmodule

