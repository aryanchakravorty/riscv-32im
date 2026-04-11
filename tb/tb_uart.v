`timescale 1ns / 1ps

module tb_uart;

    localparam integer CLK_FREQ          = 100;
    localparam integer BAUD_RATE         = 10;
    localparam integer CLKS_PER_BIT      = CLK_FREQ / BAUD_RATE;
    localparam integer NUM_BYTES         = 10;
    localparam integer RX_TIMEOUT_CYCLES = 4000;

    reg         clk;
    reg         rst;
    reg  [31:0] value_in;
    reg         trigger;
    wire        uart_tx_out;
    wire        busy;

    reg [7:0] rx_bytes [0:NUM_BYTES-1];
    reg [63:0] decoded_hex;
    reg timed_out;
    reg byte_ok;
    integer i;
    integer tx_cycles;

    uart_driver #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) DUT (
        .clk        (clk),
        .rst        (rst),
        .value_in   (value_in),
        .trigger    (trigger),
        .uart_tx_out(uart_tx_out),
        .busy       (busy)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always @(posedge clk or negedge rst) begin
        if (!rst)
            tx_cycles <= 0;
        else if (busy)
            tx_cycles <= tx_cycles + 1;
    end

    task recv_uart_byte;
        output [7:0] byte_out;
        output       ok;
        integer bit_idx;
        integer wait_cycles;
        begin
            byte_out = 8'h00;
            ok = 1'b1;
            wait_cycles = 0;

            while ((uart_tx_out !== 1'b0) && (wait_cycles < RX_TIMEOUT_CYCLES)) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (wait_cycles >= RX_TIMEOUT_CYCLES) begin
                ok = 1'b0;
            end else begin
                repeat (CLKS_PER_BIT/2) @(posedge clk);
                if (uart_tx_out !== 1'b0)
                    ok = 1'b0;

                repeat (CLKS_PER_BIT) @(posedge clk);
                for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                    byte_out[bit_idx] = uart_tx_out;
                    repeat (CLKS_PER_BIT) @(posedge clk);
                end

                if (uart_tx_out !== 1'b1)
                    ok = 1'b0;
            end
        end
    endtask

    initial begin
        rst     = 1'b0;
        trigger = 1'b0;
        value_in = 32'h00000000;
        timed_out = 1'b0;
        byte_ok = 1'b0;

        repeat (5) @(posedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);

        tx_cycles = 0;
        value_in = 32'hDEADBEEF;
        trigger  = 1'b1;
        @(posedge clk);
        trigger  = 1'b0;

        for (i = 0; i < NUM_BYTES; i = i + 1) begin
            if (!timed_out) begin
                recv_uart_byte(rx_bytes[i], byte_ok);
                if (!byte_ok)
                    timed_out = 1'b1;
            end
        end

        if (timed_out) begin
            $display("FAIL: TIMEOUT waiting for UART frame");
            $finish;
        end

        decoded_hex = {
            rx_bytes[0], rx_bytes[1], rx_bytes[2], rx_bytes[3],
            rx_bytes[4], rx_bytes[5], rx_bytes[6], rx_bytes[7]
        };

        $display("Expected frame cycles (ideal): %0d", NUM_BYTES * 10 * CLKS_PER_BIT);
        $display("Observed busy cycles:          %0d", tx_cycles);
        $display("Decoded payload:               %c%c%c%c%c%c%c%c",
                 rx_bytes[0], rx_bytes[1], rx_bytes[2], rx_bytes[3],
                 rx_bytes[4], rx_bytes[5], rx_bytes[6], rx_bytes[7]);

        if ((decoded_hex == "DEADBEEF") &&
            (rx_bytes[8] == 8'h0D) &&
            (rx_bytes[9] == 8'h0A))
            $display("PASS");
        else
            $display("FAIL");

        $finish;
    end

endmodule
