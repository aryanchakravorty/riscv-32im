`timescale 1ns/1ps

module decode
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
    input               clk,
    input               reset,
    input               stall,
    input               flush,
    input  [31:0]       pc_in,
    input  [31:0]       pc_plus4_in,
    input  [31:0]       instruction_in,
    input               valid_in,
    input               predicted_taken_in,
    input  [31:0]       btb_target_in,
    input  [31:0]       btb_pc_in,
    input  [31:0]       reg_rdata1,
    input  [31:0]       reg_rdata2,
    output [4:0]        rs1_addr,
    output [4:0]        rs2_addr,
    output reg [31:0]   pc_out,
    output reg [31:0]   pc_plus4_out,
    output reg [31:0]   rs1_data_out,
    output reg [31:0]   rs2_data_out,
    output reg [31:0]   immediate_out,
    output reg [4:0]    rs1_addr_out,
    output reg [4:0]    rs2_addr_out,
    output reg [4:0]    rd_addr_out,
    output reg [6:0]    opcode_out,
    output reg [2:0]    funct3_out,
    output reg          funct7_bit5_out,
    output reg          alu_src_out,
    output reg          mem_write_out,
    output reg          mem_read_out,
    output reg          mem_to_reg_out,
    output reg          reg_write_out,
    output reg          branch_out,
    output reg          jal_out,
    output reg          jalr_out,
    output reg          lui_out,
    output reg          auipc_out,
    output reg          is_m_ext_out,
    output reg          is_fpu_ext_out,
    output reg [4:0]    fpu_op_out,
    output reg          predicted_taken_out,
    output reg [31:0]   btb_target_out,
    output reg [31:0]   btb_pc_out,
    output reg          valid_out
);

`include "opcode.vh"

wire [6:0] opcode   = instruction_in[`OPCODE];
wire [4:0] rd       = instruction_in[`RD];
wire [2:0] funct3   = instruction_in[`FUNC3];
wire [4:0] rs1      = instruction_in[`RS1];
wire [4:0] rs2      = instruction_in[`RS2];
wire [6:0] funct7   = instruction_in[`FUNC7];
wire       funct7_5 = instruction_in[`SUBTYPE];

assign rs1_addr = rs1;
assign rs2_addr = rs2;

reg [31:0] immediate;
reg        illegal_inst;

always @(*) begin
    immediate = 32'h0;
    illegal_inst = 1'b0;
    case (opcode)
        JALR, LOAD, FLOAD, ARITHI: begin
            if (opcode == ARITHI && (funct3 == SLL || funct3 == SR))
                immediate = {27'b0, instruction_in[24:20]};
            else
                immediate = {{20{instruction_in[31]}}, instruction_in[31:20]};
        end
        STORE, FSTORE: immediate = {{20{instruction_in[31]}}, instruction_in[31:25], instruction_in[11:7]};
        BRANCH: immediate = {{19{instruction_in[31]}}, instruction_in[31], instruction_in[7], instruction_in[30:25], instruction_in[11:8], 1'b0};
        LUI, AUIPC: immediate = {instruction_in[31:12], 12'b0};
        JAL:    immediate = {{11{instruction_in[31]}}, instruction_in[31], instruction_in[19:12], instruction_in[20], instruction_in[30:21], 1'b0};
        ARITHR, FPU: immediate = 32'h0;
        default: if (valid_in && opcode != ARITHI && opcode != 0) illegal_inst = 1'b1;
    endcase
end

reg alu_src, mem_write, mem_read, mem_to_reg, reg_write, branch, jal, jalr, lui, auipc, is_m_ext, is_fpu_ext;
reg [4:0] fpu_op;

always @(*) begin
    alu_src = 0; mem_write = 0; mem_read = 0; mem_to_reg = 0; reg_write = 0;
    branch = 0; jal = 0; jalr = 0; lui = 0; auipc = 0; is_m_ext = 0; is_fpu_ext = 0;
    fpu_op = FPU_OP_FADD;
    case (opcode)
        LUI:    begin lui = 1; reg_write = 1; end
        AUIPC:  begin auipc = 1; reg_write = 1; end
        JAL:    begin jal = 1; reg_write = 1; end
        JALR:   begin jalr = 1; alu_src = 1; reg_write = 1; end
        BRANCH: begin branch = 1; end
        LOAD:   begin alu_src = 1; mem_read = 1; mem_to_reg = 1; reg_write = 1; end
        FLOAD:  begin alu_src = 1; mem_read = 1; mem_to_reg = 1; reg_write = 1; end
        STORE:  begin alu_src = 1; mem_write = 1; end
        FSTORE: begin alu_src = 1; mem_write = 1; end
        ARITHI: begin alu_src = 1; reg_write = 1; end
        ARITHR: begin 
            reg_write = 1; 
            if (funct7 == FUNC7_M) is_m_ext = 1; 
        end
        FPU: begin
            reg_write = 1;
            is_fpu_ext = 1;
            case (funct7)
                7'b0000000: fpu_op = FPU_OP_FADD;
                7'b0000100: fpu_op = FPU_OP_FSUB;
                7'b0001000: fpu_op = FPU_OP_FMUL;
                7'b0001100: fpu_op = FPU_OP_FDIV;
                7'b0010100: begin
                    case (funct3)
                        3'b000: fpu_op = FPU_OP_FMIN;
                        3'b001: fpu_op = FPU_OP_FMAX;
                        default: ;
                    endcase
                end
                7'b1010000: begin
                    case (funct3)
                        3'b010: fpu_op = FPU_OP_FEQ;
                        3'b001: fpu_op = FPU_OP_FLT;
                        3'b000: fpu_op = FPU_OP_FLE;
                        default: ;
                    endcase
                end
                7'b1100000: begin
                    if (rs2 == 5'b00000) begin
                        case (funct3)
                            3'b010: fpu_op = FPU_OP_FLR;
                            3'b011: fpu_op = FPU_OP_CEIL;
                            3'b000: fpu_op = FPU_OP_RND;
                            default: fpu_op = FPU_OP_FCVT_W_S;
                        endcase
                    end
                    else if (rs2 == 5'b00001) begin
                        fpu_op = FPU_OP_FCVT_WU_S;
                    end
                end
                7'b1101000: begin
                    if (rs2 == 5'b00000)      fpu_op = FPU_OP_FCVT_S_W;
                    else if (rs2 == 5'b00001) fpu_op = FPU_OP_FCVT_S_WU;
                end
                default: ;
            endcase
        end
        default: ;
    endcase
end

always @(posedge clk or negedge reset) begin
    if (!reset || flush) begin
        pc_out <= 0; pc_plus4_out <= 0; rs1_data_out <= 0; rs2_data_out <= 0;
        immediate_out <= 0; rs1_addr_out <= 0; rs2_addr_out <= 0; rd_addr_out <= 0;
        opcode_out <= 0;
        funct3_out <= 0; funct7_bit5_out <= 0; alu_src_out <= 0; mem_write_out <= 0;
        mem_read_out <= 0; mem_to_reg_out <= 0; reg_write_out <= 0; branch_out <= 0;
        jal_out <= 0; jalr_out <= 0; lui_out <= 0; auipc_out <= 0; is_m_ext_out <= 0;
        is_fpu_ext_out <= 0; fpu_op_out <= 0;
        predicted_taken_out <= 0; btb_target_out <= 0; btb_pc_out <= 0;
        valid_out <= 0;
    end else if (!stall) begin
        pc_out <= pc_in; pc_plus4_out <= pc_plus4_in;
        rs1_data_out <= reg_rdata1; rs2_data_out <= reg_rdata2;
        immediate_out <= immediate; rs1_addr_out <= rs1; rs2_addr_out <= rs2;
        rd_addr_out <= rd; opcode_out <= opcode;
        funct3_out <= funct3; funct7_bit5_out <= funct7_5;
        alu_src_out <= alu_src; mem_write_out <= mem_write; mem_read_out <= mem_read;
        mem_to_reg_out <= mem_to_reg; reg_write_out <= reg_write; branch_out <= branch;
        jal_out <= jal; jalr_out <= jalr; lui_out <= lui; auipc_out <= auipc;
        is_m_ext_out <= is_m_ext; is_fpu_ext_out <= is_fpu_ext; fpu_op_out <= fpu_op;
        predicted_taken_out <= predicted_taken_in; btb_target_out <= btb_target_in; btb_pc_out <= btb_pc_in;
        valid_out <= valid_in & ~illegal_inst;
    end
end
endmodule
