`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////
// Top FPGA Module for 5-Stage RISC-V Pipeline
// Memories are integrated in fetch (imem) and memory (dmem) stages
//////////////////////////////////////////////////////////////
module top_fpga #(
    parameter IMEMSIZE = 4096,
    parameter DMEMSIZE = 4096,
    parameter DEBUG_SEL_ALU = 1'b0
)(
    input  wire clk,        // Fast board clock (e.g. 100 MHz)
    input  wire reset,      // Active-low reset
    output [15:0] led
);

//////////////////////////////////////////////////////////////
// Display PC on LEDs
//////////////////////////////////////////////////////////////
wire [31:0] pc_display;
wire [31:0] alu_result_display;
wire exception;
assign led = DEBUG_SEL_ALU ? alu_result_display[15:0] : pc_display[15:0];

//////////////////////////////////////////////////////////////
// 5-Stage Pipeline CPU
// (instruction and data memories are integrated inside)
//////////////////////////////////////////////////////////////
pipe pipe_u (
    .clk        (clk),
    .reset      (reset),
    .stall      (1'b0),
    .exception  (exception),
    .pc_out     (pc_display),
    .alu_result_dbg(alu_result_display)
);

endmodule
