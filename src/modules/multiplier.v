`timescale 1ns/1ps

module multiplier (
    input  [31:0] operand1,
    input  [31:0] operand2,
    input  [2:0]  funct3,
    output [31:0] result
);

`include "opcode.vh"

wire [63:0] m_s_s = $signed(operand1) * $signed(operand2);
wire [63:0] m_u_u = $unsigned(operand1) * $unsigned(operand2);
wire [63:0] m_s_u = $signed(operand1) * $signed({1'b0, operand2});

assign result = (funct3 == MUL)    ? m_s_s[31:0] :
                (funct3 == MULH)   ? m_s_s[63:32] :
                (funct3 == MULHSU) ? m_s_u[63:32] :
                (funct3 == MULHU)  ? m_u_u[63:32] : 32'h0;

endmodule
