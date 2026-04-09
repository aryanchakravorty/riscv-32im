`timescale 1ns/1ps

module imem_model #(
    parameter LATENCY = 1
)(
    input               clk,
    input               rst,
    input  [31:0]       addr,           // byte address
    input               read_en,
    output [31:0]       data,
    output              ready
);

    reg [31:0] mem [0:1023];
    reg [31:0] counter;

    initial begin
        $readmemh("imem.hex", mem);
    end

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            counter <= 0;
        end else if (read_en) begin
            if (counter < LATENCY) begin
                counter <= counter + 1;
            end
        end else begin
            counter <= 0;
        end
    end

    // Assert ready when counter reaches LATENCY and read_en is active
    assign ready = (counter >= LATENCY) && read_en;
    
    // Address is byte-aligned, instruction memory is word-aligned
    assign data = mem[addr[11:2]];

endmodule
