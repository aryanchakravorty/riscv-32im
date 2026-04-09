`timescale 1ns/1ps

module fetch
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
    input               clk,
    input               reset,
    input               stall,
    input               flush,
    input               branch_taken,
    input  [31:0]       branch_target,
    input               btb_update_en,
    input  [31:0]       btb_update_pc,
    input               btb_actual_taken,
    input  [31:0]       btb_actual_target,
    input  [31:0]       imem_data,      // from icache
    input               imem_stall,     // from icache
    output reg [31:0]   pc_out,
    output reg [31:0]   pc_plus4_out,
    output reg [31:0]   instruction_out,
    output reg          valid_out,
    output [31:0]       current_pc,
    output reg          predicted_taken_out,
    output reg [31:0]   btb_target_out,
    output reg [31:0]   btb_pc_out
);

`include "opcode.vh"

reg [31:0] pc;
wire [31:0] pc_next;
wire        btb_hit;
wire        btb_predicted_taken;
wire [31:0] btb_target;
wire        btb_hit_comb;
wire        btb_predicted_taken_comb;
wire [31:0] btb_target_comb;
wire        btb_lookup_stall;

assign btb_lookup_stall = stall || imem_stall;
assign pc_next = branch_taken ? branch_target : (btb_hit_comb && btb_predicted_taken_comb) ? btb_target_comb : pc + 4;
assign current_pc = pc;

btb u_btb (
    .clk(clk),
    .reset(reset),
    .stall(btb_lookup_stall),
    .lookup_pc(pc),
    .btb_hit(btb_hit),
    .btb_predicted_taken(btb_predicted_taken),
    .btb_target(btb_target),
    .btb_hit_comb_out(btb_hit_comb),
    .btb_predicted_taken_comb_out(btb_predicted_taken_comb),
    .btb_target_comb_out(btb_target_comb),
    .btb_update_en(btb_update_en),
    .btb_update_pc(btb_update_pc),
    .btb_actual_taken(btb_actual_taken),
    .btb_actual_target(btb_actual_target)
);

always @(posedge clk or negedge reset) begin
    if (!reset) pc <= RESET;
    else if (!(stall || imem_stall)) pc <= pc_next;
end

always @(posedge clk or negedge reset) begin
    if (!reset || flush) begin
        pc_out <= 0;
        pc_plus4_out <= 0;
        instruction_out <= NOP;
        valid_out <= 0;
        predicted_taken_out <= 0;
        btb_target_out <= 0;
        btb_pc_out <= 0;
    end else if (!(stall || imem_stall)) begin
        pc_out <= pc;
        pc_plus4_out <= pc + 4;
        instruction_out <= imem_data;
        valid_out <= 1;
        predicted_taken_out <= btb_predicted_taken_comb;
        btb_target_out <= btb_target_comb;
        btb_pc_out <= pc;
    end
end

endmodule
