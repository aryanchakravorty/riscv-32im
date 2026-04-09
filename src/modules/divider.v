`timescale 1ns/1ps

module divider (
    input               clk,
    input               reset,
    input               start,
    input  [31:0]       operand1,
    input  [31:0]       operand2,
    input  [2:0]        funct3,
    output reg [31:0]   result,
    output              busy
);

`include "opcode.vh"

localparam IDLE = 0, DIVIDE = 1, FINISH = 2;
reg [1:0] state;
reg [5:0] count;

reg [31:0] abs_op1;
reg [31:0] abs_op2;
reg [31:0] remainder_reg;
reg        neg_quotient;
reg        neg_remainder;
reg [31:0] saved_op1;

assign busy = (state != IDLE) || start;

wire is_signed = (funct3 == DIV || funct3 == REM);

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        state         <= IDLE;
        count         <= 0;
        result        <= 32'h0;
        abs_op1       <= 32'h0;
        abs_op2       <= 32'h0;
        remainder_reg <= 32'h0;
        neg_quotient  <= 1'b0;
        neg_remainder <= 1'b0;
        saved_op1     <= 32'h0;
    end
    else begin
        case (state)
            IDLE: begin
                if (start) begin
                    saved_op1 <= operand1;
                    if (operand2 == 0) begin
                        case (funct3)
                            DIV, DIVU: result <= 32'hFFFF_FFFF;
                            REM, REMU: result <= operand1;
                            default:   result <= 32'h0;
                        endcase
                        state <= FINISH;
                    end
                    else if (is_signed && operand1 == 32'h8000_0000 && operand2 == 32'hFFFF_FFFF) begin
                        case (funct3)
                            DIV:       result <= 32'h8000_0000;
                            REM:       result <= 32'h0;
                            default:   result <= 32'h0;
                        endcase
                        state <= FINISH;
                    end
                    else begin
                        state         <= DIVIDE;
                        count         <= 6'd32;
                        remainder_reg <= 32'h0;
                        abs_op1       <= (is_signed && operand1[31]) ? -operand1 : operand1;
                        abs_op2       <= (is_signed && operand2[31]) ? -operand2 : operand2;
                        neg_quotient  <= is_signed && (operand1[31] ^ operand2[31]);
                        neg_remainder <= is_signed && operand1[31];
                    end
                end
            end
            
            DIVIDE: begin
                if (count == 0) begin
                    state <= FINISH;
                    case (funct3)
                        DIV, DIVU: result <= neg_quotient  ? -abs_op1 : abs_op1;
                        REM, REMU: result <= neg_remainder ? -remainder_reg : remainder_reg;
                        default:   result <= 32'h0;
                    endcase
                end
                else begin
                    // One bit step of restored division
                    if ({remainder_reg[30:0], abs_op1[31]} >= abs_op2) begin
                        remainder_reg <= {remainder_reg[30:0], abs_op1[31]} - abs_op2;
                        abs_op1       <= {abs_op1[30:0], 1'b1};
                    end
                    else begin
                        remainder_reg <= {remainder_reg[30:0], abs_op1[31]};
                        abs_op1       <= {abs_op1[30:0], 1'b0};
                    end
                    count <= count - 1;
                end
            end
            
            FINISH: begin
                state <= IDLE;
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
