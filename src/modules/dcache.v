`timescale 1ns/1ps

module dcache (
    input               clk,
    input               rst,
    input  [31:0]       addr,
    input  [31:0]       write_data,
    input  [3:0]        write_strobe,
    input               read_en,
    input               write_en,
    output [31:0]       read_data,
    output              stall,
    output wire         hit_pulse,
    output wire         miss_pulse,
    output wire         writeback_pulse,

    output reg [31:0]   mem_addr,
    output reg [31:0]   mem_wdata,
    output reg [3:0]    mem_wstrobe,
    output reg          mem_read,
    output reg          mem_write,
    input  [31:0]       mem_rdata,
    input               mem_ready,

    output reg [31:0]   hit_count,
    output reg [31:0]   miss_count,
    output reg [31:0]   writeback_count
);

`include "opcode.vh"

localparam IDLE  = 2'd0;
localparam EVICT = 2'd1;
localparam FILL  = 2'd2;

reg [1:0] state;

reg [19:0]   tag_array   [0:127];
reg          valid_array [0:127];
reg          dirty_array [0:127];
reg [255:0]  data_array  [0:127];

reg [31:0] line_buffer [0:7];

reg [2:0]   fill_count;
reg [2:0]   evict_count;
reg [255:0] evict_line_snapshot;
reg [31:0]  pending_write_data;
reg [3:0]   pending_write_strobe;
reg         has_pending_write;
reg [19:0]  req_tag;
reg [6:0]   req_index;
reg [2:0]   req_word_off;
reg [31:0]  miss_read_data;
reg         just_filled;

wire [19:0] addr_tag      = addr[31:12];
wire [6:0]  addr_index    = addr[11:5];
wire [2:0]  addr_word_off = addr[4:2];

wire        cache_hit     = valid_array[addr_index] && (tag_array[addr_index] == addr_tag);
wire [31:0] hit_read_data = data_array[addr_index][addr_word_off*32 +: 32];

reg stall_r;
assign stall = stall_r;
assign hit_pulse       = (state == IDLE) && (read_en || write_en) && cache_hit && !just_filled;
assign miss_pulse      = (state == IDLE) && (read_en || write_en) && !cache_hit;
assign writeback_pulse = (state == EVICT) && (evict_count == 3'd0) && mem_ready;
assign read_data = (state == IDLE && read_en && cache_hit) ? hit_read_data : miss_read_data;

always @(*) begin
    stall_r = (state != IDLE);
    if (state == IDLE) begin
        if (read_en && !cache_hit) begin
            stall_r = 1'b1;
        end else if (write_en && !cache_hit) begin
            stall_r = 1'b1;
        end else begin
            stall_r = 1'b0;
        end
    end
end

integer i;
integer j;
always @(posedge clk or negedge rst) begin
    if (!rst) begin
        state                <= IDLE;
        mem_addr             <= 32'h0;
        mem_wdata            <= 32'h0;
        mem_wstrobe          <= 4'b0;
        mem_read             <= 1'b0;
        mem_write            <= 1'b0;
        hit_count            <= 32'h0;
        miss_count           <= 32'h0;
        writeback_count      <= 32'h0;
        fill_count           <= 3'h0;
        evict_count          <= 3'h0;
        evict_line_snapshot  <= 256'h0;
        pending_write_data   <= 32'h0;
        pending_write_strobe <= 4'h0;
        has_pending_write    <= 1'b0;
        req_tag              <= 20'h0;
        req_index            <= 7'h0;
        req_word_off         <= 3'h0;
        miss_read_data       <= 32'h0;
        just_filled          <= 1'b0;

        for (i = 0; i < `D_NUM_SETS; i = i + 1) begin
            tag_array[i]   <= {`D_TAG_BITS{1'b0}};
            valid_array[i] <= 1'b0;
            dirty_array[i] <= 1'b0;
            data_array[i]  <= {(`LINE_SIZE*8){1'b0}};
        end

        for (j = 0; j < 8; j = j + 1) begin
            line_buffer[j] <= 32'h0;
        end
    end else begin
        case (state)
            IDLE: begin
                mem_read    <= 1'b0;
                mem_write   <= 1'b0;
                mem_wstrobe <= 4'b0;
                just_filled <= 1'b0;

                if (read_en) begin
                    if (cache_hit) begin
                        hit_count      <= hit_count + 1'b1;
                        miss_read_data <= hit_read_data;
                    end else begin
                        miss_count        <= miss_count + 1'b1;
                        req_tag           <= addr_tag;
                        req_index         <= addr_index;
                        req_word_off      <= addr_word_off;
                        has_pending_write <= 1'b0;
                        if (valid_array[addr_index] && dirty_array[addr_index]) begin
                            evict_line_snapshot <= data_array[addr_index];
                            evict_count         <= 3'd0;
                            writeback_count     <= writeback_count + 1'b1;
                            mem_write           <= 1'b1;
                            mem_wstrobe         <= 4'b1111;
                            mem_addr            <= {tag_array[addr_index], addr_index, 5'b00000};
                            mem_wdata           <= data_array[addr_index][31:0];
                            state               <= EVICT;
                        end else begin
                            mem_read   <= 1'b1;
                            fill_count <= 3'd0;
                            mem_addr   <= {addr_tag, addr_index, 5'b00000};
                            state      <= FILL;
                        end
                    end
                end else if (write_en) begin
                    if (cache_hit) begin
                        hit_count <= hit_count + 1'b1;
                        if (write_strobe[0]) data_array[addr_index][addr_word_off*32 +: 8]      <= write_data[7:0];
                        if (write_strobe[1]) data_array[addr_index][addr_word_off*32+8 +: 8]    <= write_data[15:8];
                        if (write_strobe[2]) data_array[addr_index][addr_word_off*32+16 +: 8]   <= write_data[23:16];
                        if (write_strobe[3]) data_array[addr_index][addr_word_off*32+24 +: 8]   <= write_data[31:24];
                        dirty_array[addr_index] <= 1'b1;
                    end else begin
                        miss_count           <= miss_count + 1'b1;
                        req_tag              <= addr_tag;
                        req_index            <= addr_index;
                        req_word_off         <= addr_word_off;
                        pending_write_data   <= write_data;
                        pending_write_strobe <= write_strobe;
                        has_pending_write    <= 1'b1;
                        if (valid_array[addr_index] && dirty_array[addr_index]) begin
                            evict_line_snapshot <= data_array[addr_index];
                            evict_count         <= 3'd0;
                            writeback_count     <= writeback_count + 1'b1;
                            mem_write           <= 1'b1;
                            mem_wstrobe         <= 4'b1111;
                            mem_addr            <= {tag_array[addr_index], addr_index, 5'b00000};
                            mem_wdata           <= data_array[addr_index][31:0];
                            state               <= EVICT;
                        end else begin
                            mem_read   <= 1'b1;
                            fill_count <= 3'd0;
                            mem_addr   <= {addr_tag, addr_index, 5'b00000};
                            state      <= FILL;
                        end
                    end
                end
            end

            EVICT: begin
                mem_read    <= 1'b0;
                mem_write   <= 1'b1;
                mem_wstrobe <= 4'b1111;

                if (mem_ready) begin
                    if (evict_count == 3'd7) begin
                        dirty_array[req_index] <= 1'b0;
                        mem_write   <= 1'b0;
                        mem_read    <= 1'b1;
                        fill_count  <= 3'd0;
                        mem_addr    <= {req_tag, req_index, 5'b00000};
                        state       <= FILL;
                    end else begin
                        evict_count <= evict_count + 1'b1;
                        mem_addr    <= mem_addr + 32'd4;
                        mem_wdata   <= evict_line_snapshot[(evict_count+1)*32 +: 32];
                    end
                end
            end

            FILL: begin
                mem_read    <= 1'b1;
                mem_write   <= 1'b0;
                mem_wstrobe <= 4'b0;

                if (mem_ready) begin
                    line_buffer[fill_count] <= mem_rdata;
                    if (fill_count == 3'd7) begin
                        valid_array[req_index] <= 1'b1;
                        tag_array[req_index]   <= req_tag;
                        data_array[req_index]  <= {mem_rdata, line_buffer[6], line_buffer[5], line_buffer[4],
                                                   line_buffer[3], line_buffer[2], line_buffer[1], line_buffer[0]};

                        if (has_pending_write) begin
                            dirty_array[req_index] <= 1'b1;
                            if (pending_write_strobe[0]) data_array[req_index][req_word_off*32 +: 8]     <= pending_write_data[7:0];
                            if (pending_write_strobe[1]) data_array[req_index][req_word_off*32+8 +: 8]   <= pending_write_data[15:8];
                            if (pending_write_strobe[2]) data_array[req_index][req_word_off*32+16 +: 8]  <= pending_write_data[23:16];
                            if (pending_write_strobe[3]) data_array[req_index][req_word_off*32+24 +: 8]  <= pending_write_data[31:24];
                        end else begin
                            dirty_array[req_index] <= 1'b0;
                        end

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

                        has_pending_write <= 1'b0;
                        mem_read          <= 1'b0;
                        state             <= IDLE;
                        just_filled       <= 1'b1;
                    end else begin
                        fill_count <= fill_count + 1'b1;
                        mem_addr   <= mem_addr + 32'd4;
                    end
                end
            end

            default: begin
                state       <= IDLE;
                mem_read    <= 1'b0;
                mem_write   <= 1'b0;
                mem_wstrobe <= 4'b0;
            end
        endcase
    end
end

endmodule
