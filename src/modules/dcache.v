`timescale 1ns/1ps

module dcache (
    input               clk,
    input               rst,
    input  [31:0]       addr,          // byte address from EX/MEM
    input  [31:0]       write_data,    // rs2_data
    input  [3:0]        write_strobe,  // byte enables
    input               read_en,       // mem_read_in
    input               write_en,      // mem_write_in
    output [31:0]       read_data,
    output              stall,

    // Memory interface (to dmem_model)
    output reg [31:0]   mem_addr,
    output reg [31:0]   mem_wdata,
    output reg [3:0]    mem_wstrobe,
    output reg          mem_read,
    output reg          mem_write,
    input  [31:0]       mem_rdata,
    input               mem_ready,

    // Performance counters
    output reg [31:0]   hit_count,
    output reg [31:0]   miss_count
);

`include "opcode.vh"

localparam IDLE      = 2'd0;
localparam MISS_READ = 2'd1;
localparam FILL      = 2'd2;
localparam WRITE_MEM = 2'd3;

reg [1:0] state;
reg       dcache_busy;

// Direct-mapped arrays
reg [`TAG_BITS-1:0]     tag_array   [0:`NUM_SETS-1];
reg                     valid_array [0:`NUM_SETS-1];
reg [`LINE_SIZE*8-1:0]  data_array  [0:`NUM_SETS-1];

reg [2:0]  fill_count;
reg [31:0] line_buffer [0:7];
reg        suppress_once;
reg [31:0] miss_read_data;

// Captured request info
reg [`TAG_BITS-1:0]    req_tag;
reg [`INDEX_BITS-1:0]  req_index;
reg [2:0]              req_word_off;
reg [31:0]             req_write_addr;
reg [31:0]             req_write_data;
reg [3:0]              req_write_strobe;

wire [`TAG_BITS-1:0]   addr_tag      = addr[31:11];
wire [`INDEX_BITS-1:0] addr_index    = addr[10:5];
wire [2:0]             addr_word_off = addr[4:2];
wire                   hit_condition = valid_array[addr_index] && (tag_array[addr_index] == addr_tag);
wire [31:0]            hit_read_data = data_array[addr_index][addr_word_off*32 +: 32];
wire will_start_read_miss = (state == IDLE) && !suppress_once && read_en && !hit_condition;
wire will_start_write     = (state == IDLE) && !suppress_once && write_en;
assign stall = (state != IDLE) || will_start_read_miss || will_start_write;
assign read_data = ((state == IDLE) && read_en && hit_condition) ? hit_read_data : miss_read_data;

integer i;
always @(posedge clk or negedge rst) begin
    if (!rst) begin
        state         <= IDLE;
        dcache_busy   <= 1'b0;
        miss_read_data <= 32'h0;
        mem_addr      <= 32'h0;
        mem_wdata     <= 32'h0;
        mem_wstrobe   <= 4'b0;
        mem_read      <= 1'b0;
        mem_write     <= 1'b0;
        hit_count     <= 32'h0;
        miss_count    <= 32'h0;
        fill_count    <= 3'h0;
        suppress_once <= 1'b0;
        req_tag       <= {`TAG_BITS{1'b0}};
        req_index     <= {`INDEX_BITS{1'b0}};
        req_word_off  <= 3'h0;
        req_write_addr   <= 32'h0;
        req_write_data   <= 32'h0;
        req_write_strobe <= 4'b0;

        for (i = 0; i < `NUM_SETS; i = i + 1) begin
            tag_array[i]   <= {`TAG_BITS{1'b0}};
            valid_array[i] <= 1'b0;
            data_array[i]  <= {(`LINE_SIZE*8){1'b0}};
        end
    end else begin
        case (state)
            IDLE: begin
                dcache_busy <= 1'b0;
                mem_read    <= 1'b0;
                mem_write   <= 1'b0;
                mem_wstrobe <= 4'b0;
                if (suppress_once) begin
                    suppress_once <= 1'b0;
                end else begin
                    if (read_en) begin
                        if (hit_condition) begin
                            hit_count  <= hit_count + 1'b1;
                        end else begin
                            // Read miss -> fetch full line.
                            req_tag      <= addr_tag;
                            req_index    <= addr_index;
                            req_word_off <= addr_word_off;
                            fill_count   <= 3'd0;
                            miss_count   <= miss_count + 1'b1;

                            mem_addr    <= {addr[31:5], 5'b0}; // line-aligned
                            mem_read    <= 1'b1;
                            dcache_busy <= 1'b1;
                            state       <= MISS_READ;
                        end
                    end else if (write_en) begin
                        if (hit_condition) begin
                            // Write-through + write hit update in cache line.
                            if (write_strobe[0]) data_array[addr_index][addr_word_off*32 +: 8]       <= write_data[7:0];
                            if (write_strobe[1]) data_array[addr_index][addr_word_off*32 + 8 +: 8]   <= write_data[15:8];
                            if (write_strobe[2]) data_array[addr_index][addr_word_off*32 + 16 +: 8]  <= write_data[23:16];
                            if (write_strobe[3]) data_array[addr_index][addr_word_off*32 + 24 +: 8]  <= write_data[31:24];
                            hit_count <= hit_count + 1'b1;
                        end
                        // No-allocate on write miss: always forward write to memory.
                        req_write_addr   <= addr;
                        req_write_data   <= write_data;
                        req_write_strobe <= write_strobe;

                        mem_addr    <= addr;
                        mem_wdata   <= write_data;
                        mem_wstrobe <= write_strobe;
                        mem_write   <= 1'b1;
                        dcache_busy <= 1'b1;
                        state       <= WRITE_MEM;
                    end
                end
            end

            MISS_READ: begin
                mem_read  <= 1'b1;
                mem_write <= 1'b0;
                if (mem_ready) begin
                    line_buffer[0] <= mem_rdata;
                    fill_count     <= 3'd1;
                    mem_addr       <= mem_addr + 32'd4;
                    state          <= FILL;
                end
            end

            FILL: begin
                mem_read  <= 1'b1;
                mem_write <= 1'b0;
                if (mem_ready) begin
                    line_buffer[fill_count] <= mem_rdata;
                    if (fill_count == 3'd7) begin
                        valid_array[req_index] <= 1'b1;
                        tag_array[req_index]   <= req_tag;
                        data_array[req_index]  <= {mem_rdata, line_buffer[6], line_buffer[5], line_buffer[4],
                                                   line_buffer[3], line_buffer[2], line_buffer[1], line_buffer[0]};

                        case (req_word_off)
                            3'd0: miss_read_data <= line_buffer[0];
                            3'd1: miss_read_data <= line_buffer[1];
                            3'd2: miss_read_data <= line_buffer[2];
                            3'd3: miss_read_data <= line_buffer[3];
                            3'd4: miss_read_data <= line_buffer[4];
                            3'd5: miss_read_data <= line_buffer[5];
                            3'd6: miss_read_data <= line_buffer[6];
                            3'd7: miss_read_data <= mem_rdata;
                            default: miss_read_data <= 32'h0;
                        endcase

                        mem_read    <= 1'b0;
                        dcache_busy <= 1'b0;
                        suppress_once <= 1'b1;
                        state       <= IDLE;
                    end else begin
                        fill_count <= fill_count + 1'b1;
                        mem_addr   <= mem_addr + 32'd4;
                    end
                end
            end

            WRITE_MEM: begin
                mem_read    <= 1'b0;
                mem_write   <= 1'b1;
                mem_addr    <= req_write_addr;
                mem_wdata   <= req_write_data;
                mem_wstrobe <= req_write_strobe;
                if (mem_ready) begin
                    mem_write   <= 1'b0;
                    mem_wstrobe <= 4'b0;
                    dcache_busy <= 1'b0;
                    suppress_once <= 1'b1;
                    state       <= IDLE;
                end
            end

            default: begin
                state <= IDLE;
            end
        endcase
    end
end

endmodule
