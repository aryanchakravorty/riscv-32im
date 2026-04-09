`timescale 1ns/1ps

module writeback
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
    input               clk,
    input               reset,
    
    // From MEM/WB register
    input  [31:0]       pc_plus4_in,
    input  [31:0]       alu_result_in,
    input  [31:0]       mem_read_data_in,
    input  [4:0]        rd_addr_in,
    input  [2:0]        funct3_in,
    input               is_fpu_ext_in,
    input  [4:0]        fpu_op_in,
    
    // Control signals from MEM/WB
    input               mem_to_reg_in,
    input               reg_write_in,
    input               valid_in,
    
    // Outputs to register file
    output              reg_write_en,
    output [4:0]        rd_addr,
    output [31:0]       rd_data,
    
    // For forwarding (MEM/WB result)
    output [31:0]       forward_data
);

wire [31:0] writeback_data = mem_to_reg_in ? mem_read_data_in : alu_result_in;

assign reg_write_en = reg_write_in && valid_in && (rd_addr_in != 5'd0);
assign rd_addr      = rd_addr_in;
assign rd_data      = writeback_data;
assign forward_data = writeback_data;

endmodule
