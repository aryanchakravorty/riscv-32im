`timescale 1ns / 1ps

module top_fpga #(
    parameter IMEMSIZE = 4096,
    parameter DMEMSIZE = 4096,
    parameter DEBUG_SEL_ALU = 1'b0
) (
    input  wire clk,
    input  wire reset,
    input  wire btn_send,
    output wire [15:0] led,
    output wire uart_tx
);

    wire [31:0] pc_display;
    wire [31:0] alu_result_display;
    wire exception;
    reg btn_prev;
    wire btn_edge;

    assign led = DEBUG_SEL_ALU ? alu_result_display[15:0] : pc_display[15:0];
    assign btn_edge = btn_send && !btn_prev;

    always @(posedge clk or negedge reset) begin
        if (!reset)
            btn_prev <= 1'b0;
        else
            btn_prev <= btn_send;
    end

    pipe pipe_u (
        .clk           (clk),
        .reset         (reset),
        .stall         (1'b0),
        .exception     (exception),
        .pc_out        (pc_display),
        .alu_result_dbg(alu_result_display)
    );

    uart_driver u_uart (
        .clk        (clk),
        .rst        (reset),
        .value_in   (pc_display),
        .trigger    (btn_edge),
        .uart_tx_out(uart_tx),
        .busy       ()
    );

endmodule
