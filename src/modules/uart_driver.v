`timescale 1ns / 1ps

module uart_driver #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115200
) (
    input         clk,
    input         rst,
    input  [31:0] value_in,
    input         trigger,
    output        uart_tx_out,
    output        busy
);

    function [7:0] hex_to_ascii;
        input [3:0] nibble;
        begin
            if (nibble < 4'd10)
                hex_to_ascii = 8'h30 + {4'b0000, nibble};
            else
                hex_to_ascii = 8'h41 + ({4'b0000, nibble} - 8'd10);
        end
    endfunction

    reg  [79:0] tx_shift;
    reg  [3:0]  bytes_left;
    reg         send_pulse;
    reg         wait_busy_high;
    reg         active;
    wire        tx_busy;
    wire [7:0]  tx_byte;

    assign tx_byte = tx_shift[79:72];

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_uart_tx (
        .clk    (clk),
        .rst    (rst),
        .data_in(tx_byte),
        .send   (send_pulse),
        .tx     (uart_tx_out),
        .busy   (tx_busy)
    );

    assign busy = active || tx_busy;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            tx_shift   <= 80'd0;
            bytes_left <= 4'd0;
            send_pulse <= 1'b0;
            wait_busy_high <= 1'b0;
            active     <= 1'b0;
        end else begin
            send_pulse <= 1'b0;

            if (!active && !tx_busy && trigger) begin
                tx_shift <= {
                    hex_to_ascii(value_in[31:28]),
                    hex_to_ascii(value_in[27:24]),
                    hex_to_ascii(value_in[23:20]),
                    hex_to_ascii(value_in[19:16]),
                    hex_to_ascii(value_in[15:12]),
                    hex_to_ascii(value_in[11:8]),
                    hex_to_ascii(value_in[7:4]),
                    hex_to_ascii(value_in[3:0]),
                    8'h0D,
                    8'h0A
                };
                bytes_left      <= 4'd10;
                wait_busy_high  <= 1'b0;
                active          <= 1'b1;
            end else if (active) begin
                if (bytes_left != 4'd0) begin
                    if (!wait_busy_high && !tx_busy) begin
                        send_pulse <= 1'b1;
                        wait_busy_high <= 1'b1;
                    end else if (wait_busy_high && tx_busy) begin
                        tx_shift       <= {tx_shift[71:0], 8'h00};
                        bytes_left     <= bytes_left - 1'b1;
                        wait_busy_high <= 1'b0;
                    end
                end else if (!tx_busy) begin
                    active         <= 1'b0;
                    wait_busy_high <= 1'b0;
                end
            end
        end
    end

endmodule
