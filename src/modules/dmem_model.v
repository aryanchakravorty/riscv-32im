`timescale 1ns/1ps

module dmem_model #(
    parameter LATENCY = 10
)(
    input               clk,
    input  [31:0]       addr,       // byte address
    input  [31:0]       wdata,
    input  [3:0]        wstrobe,    // byte enables
    input               read_en,
    input               write_en,
    output [31:0]       rdata,
    output              ready
);

    (* ram_style = "distributed" *)
    reg [31:0] mem [0:1023];

    reg [31:0] counter;
    wire       req_active = read_en || write_en;
    wire [9:0] mem_index = addr[11:2];
    integer    i;
    integer    init_fd;

    initial begin
        for (i = 0; i < 1024; i = i + 1) begin
            mem[i] = 32'h0;
        end

        // Prefer dmem.hex (flat word image) to avoid out-of-range @address files.
        init_fd = $fopen("dmem.hex", "r");
        if (init_fd != 0) begin
            $fclose(init_fd);
            $readmemh("dmem.hex", mem);
        end
        else begin
            init_fd = $fopen("dmem_final.hex", "r");
            if (init_fd != 0) begin
                $fclose(init_fd);
                $readmemh("dmem_final.hex", mem);
            end
        end

        counter     = 32'h0;
    end

    always @(posedge clk) begin
        if (!req_active) begin
            counter <= 32'h0;
        end else if (counter < LATENCY) begin
            counter <= counter + 1'b1;
        end

        if (write_en && ready) begin
            if (wstrobe[0]) mem[mem_index][7:0]   <= wdata[7:0];
            if (wstrobe[1]) mem[mem_index][15:8]  <= wdata[15:8];
            if (wstrobe[2]) mem[mem_index][23:16] <= wdata[23:16];
            if (wstrobe[3]) mem[mem_index][31:24] <= wdata[31:24];
        end
    end

    assign rdata = mem[mem_index];
    assign ready = req_active && (counter >= LATENCY);

endmodule
