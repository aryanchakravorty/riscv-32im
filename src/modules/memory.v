`timescale 1ns/1ps

module memory
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
    input               clk,
    input               reset,
    input               stall,
    input               flush,
    
    // From EX/MEM register
    input  [31:0]       pc_plus4_in,
    input  [31:0]       alu_result_in,
    input  [31:0]       rs2_data_in,
    input  [4:0]        rd_addr_in,
    input  [2:0]        funct3_in,
    input               is_fpu_ext_in,
    input  [4:0]        fpu_op_in,
    
    // Control signals from EX/MEM
    input               mem_write_in,
    input               mem_read_in,
    input               mem_to_reg_in,
    input               reg_write_in,
    input               valid_in,
    
    // Outputs to MEM/WB register
    output reg [31:0]   pc_plus4_out,
    output reg [31:0]   alu_result_out,
    output reg [31:0]   mem_read_data_out,
    output reg [4:0]    rd_addr_out,
    output reg [2:0]    funct3_out,
    output reg          is_fpu_ext_out,
    output reg [4:0]    fpu_op_out,
    
    // Control signals to MEM/WB
    output reg          mem_to_reg_out,
    output reg          reg_write_out,
    output reg          valid_out,
    
    // For forwarding (EX/MEM result)
    output [31:0]       forward_data,

    // D-Cache interface
    input  [31:0]       dcache_read_data,
    input               dcache_stall,
    output [31:0]       dcache_addr,
    output [31:0]       dcache_wdata,
    output [3:0]        dcache_wstrobe,
    output              dcache_read_en,
    output              dcache_write_en
);

`include "opcode.vh"

wire [31:0] mem_addr = alu_result_in;
wire [1:0]  byte_offset = mem_addr[1:0];

// Store data alignment
reg [31:0] write_data;
reg [3:0]  write_strobe;

always @(*) begin
    write_data   = 32'h0;
    write_strobe = 4'b0000;
    if (mem_write_in && valid_in) begin
        case (funct3_in)
            SB: begin
                case (byte_offset)
                    2'b00: begin write_data[7:0]   = rs2_data_in[7:0];  write_strobe = 4'b0001; end
                    2'b01: begin write_data[15:8]  = rs2_data_in[7:0];  write_strobe = 4'b0010; end
                    2'b10: begin write_data[23:16] = rs2_data_in[7:0];  write_strobe = 4'b0100; end
                    2'b11: begin write_data[31:24] = rs2_data_in[7:0];  write_strobe = 4'b1000; end
                endcase
            end
            SH: begin
                if (byte_offset[1]) begin write_data[31:16] = rs2_data_in[15:0]; write_strobe = 4'b1100; end
                else begin write_data[15:0]  = rs2_data_in[15:0]; write_strobe = 4'b0011; end
            end
            SW: begin write_data   = rs2_data_in; write_strobe = 4'b1111; end // SW/FSW (funct3=010)
            default: ;
        endcase
    end
end

assign dcache_addr     = mem_addr;
assign dcache_wdata    = write_data;
assign dcache_wstrobe  = write_strobe;
assign dcache_read_en  = mem_read_in && valid_in;
assign dcache_write_en = mem_write_in && valid_in;

// Byte/halfword alignment from dcache returned 32-bit word
wire [31:0] raw_read_val = dcache_read_data;
reg [31:0] aligned_read_val;

always @(*) begin
    aligned_read_val = raw_read_val;
    if (mem_read_in) begin
        case (funct3_in)
            LB: begin
                case (byte_offset)
                    2'b00: aligned_read_val = {{24{raw_read_val[7]}},  raw_read_val[7:0]};
                    2'b01: aligned_read_val = {{24{raw_read_val[15]}}, raw_read_val[15:8]};
                    2'b10: aligned_read_val = {{24{raw_read_val[23]}}, raw_read_val[23:16]};
                    2'b11: aligned_read_val = {{24{raw_read_val[31]}}, raw_read_val[31:24]};
                endcase
            end
            LH: begin
                if (byte_offset[1]) aligned_read_val = {{16{raw_read_val[31]}}, raw_read_val[31:16]};
                else aligned_read_val = {{16{raw_read_val[15]}}, raw_read_val[15:0]};
            end
            LW:  aligned_read_val = raw_read_val; // LW/FLW (funct3=010)
            LBU: begin
                case (byte_offset)
                    2'b00: aligned_read_val = {24'h0, raw_read_val[7:0]};
                    2'b01: aligned_read_val = {24'h0, raw_read_val[15:8]};
                    2'b10: aligned_read_val = {24'h0, raw_read_val[23:16]};
                    2'b11: aligned_read_val = {24'h0, raw_read_val[31:24]};
                endcase
            end
            LHU: begin
                if (byte_offset[1]) aligned_read_val = {16'h0, raw_read_val[31:16]};
                else aligned_read_val = {16'h0, raw_read_val[15:0]};
            end
            default: ;
        endcase
    end
end

assign forward_data = mem_to_reg_in ? aligned_read_val : alu_result_in;

always @(posedge clk or negedge reset) begin
    if (!reset || flush) begin
        pc_plus4_out        <= 0;
        alu_result_out      <= 0;
        mem_read_data_out   <= 0;
        rd_addr_out         <= 0;
        funct3_out          <= 0;
        is_fpu_ext_out      <= 0;
        fpu_op_out          <= 0;
        mem_to_reg_out      <= 0;
        reg_write_out       <= 0;
        valid_out           <= 0;
    end
    else if (!(stall || dcache_stall)) begin
        pc_plus4_out        <= pc_plus4_in;
        alu_result_out      <= alu_result_in;
        mem_read_data_out   <= aligned_read_val;
        rd_addr_out         <= rd_addr_in;
        funct3_out          <= funct3_in;
        is_fpu_ext_out      <= is_fpu_ext_in;
        fpu_op_out          <= fpu_op_in;
        mem_to_reg_out      <= mem_to_reg_in;
        reg_write_out       <= reg_write_in;
        valid_out           <= valid_in;
    end
end
endmodule
