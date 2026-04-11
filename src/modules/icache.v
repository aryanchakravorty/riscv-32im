`timescale 1ns/1ps

module icache (
    input               clk,
    input               rst,
    input  [31:0]       pc,
    input               read_en,
    output wire [31:0]  instruction,
    output              stall,
    output wire         hit_pulse,
    output wire         miss_pulse,
    output reg [31:0]   mem_addr,
    output reg          mem_read,
    input  [31:0]       mem_data,
    input               mem_ready
);

`include "opcode.vh"

wire [`TAG_BITS-1:0]    pc_tag    = pc[31:11];
wire [`INDEX_BITS-1:0]  pc_index  = pc[10:5];
wire [2:0]              word_off  = pc[4:2];

reg [`TAG_BITS-1:0]      tag_array0   [0:`NUM_SETS-1];
reg [`TAG_BITS-1:0]      tag_array1   [0:`NUM_SETS-1];
reg                     valid_array0 [0:`NUM_SETS-1];
reg                     valid_array1 [0:`NUM_SETS-1];
reg [`LINE_SIZE*8-1:0]   data_array0  [0:`NUM_SETS-1];
reg [`LINE_SIZE*8-1:0]   data_array1  [0:`NUM_SETS-1];
reg                     lru          [0:`NUM_SETS-1];

localparam IDLE = 2'd0;
localparam MISS = 2'd1;
localparam FILL = 2'd2;

reg [1:0] state;
reg [2:0] fill_count;
reg [31:0] line_buffer [0:7];

wire hit0 = valid_array0[pc_index] && (tag_array0[pc_index] == pc_tag);
wire hit1 = valid_array1[pc_index] && (tag_array1[pc_index] == pc_tag);
wire hit  = hit0 || hit1;

assign stall = read_en && !hit;
assign instruction = hit0 ? data_array0[pc_index][word_off*32 +: 32] :
                    (hit1 ? data_array1[pc_index][word_off*32 +: 32] : NOP);
assign hit_pulse  = (state == IDLE) && read_en &&  hit;
assign miss_pulse = (state == IDLE) && read_en && !hit;

integer i;
initial begin
    for (i = 0; i < `NUM_SETS; i = i + 1) begin
        valid_array0[i] = 0;
        valid_array1[i] = 0;
        lru[i] = 0;
    end
end

always @(posedge clk or negedge rst) begin
    if (!rst) begin
        state <= IDLE;
        mem_read <= 0;
        mem_addr <= 0;
        fill_count <= 0;
    end else begin
        case (state)
            IDLE: begin
                if (read_en) begin
                    if (hit) begin
                        if (!stall) begin
                            if (hit0) begin
                                lru[pc_index] <= 1;
                            end else begin
                                lru[pc_index] <= 0;
                            end
                        end
                    end else begin
                        state <= MISS;
                        mem_addr <= {pc[31:5], 5'b00000};
                        mem_read <= 1;
                    end
                end
            end

            MISS: begin
                if (mem_ready) begin
                    line_buffer[0] <= mem_data;
                    mem_addr <= mem_addr + 4;
                    fill_count <= 1;
                    state <= FILL;
                end
            end

            FILL: begin
                if (mem_ready) begin
                    line_buffer[fill_count] <= mem_data;
                    if (fill_count == 7) begin
                        if (lru[pc_index] == 0) begin
                            tag_array0[pc_index]   <= pc_tag;
                            valid_array0[pc_index] <= 1;
                            data_array0[pc_index]  <= {mem_data, line_buffer[6], line_buffer[5], line_buffer[4],
                                                        line_buffer[3], line_buffer[2], line_buffer[1], line_buffer[0]};
                            lru[pc_index] <= 1;
                        end else begin
                            tag_array1[pc_index]   <= pc_tag;
                            valid_array1[pc_index] <= 1;
                            data_array1[pc_index]  <= {mem_data, line_buffer[6], line_buffer[5], line_buffer[4],
                                                        line_buffer[3], line_buffer[2], line_buffer[1], line_buffer[0]};
                            lru[pc_index] <= 0;
                        end
                        mem_read <= 0;
                        state <= IDLE;
                    end else begin
                        mem_addr <= mem_addr + 4;
                        fill_count <= fill_count + 1;
                    end
                end
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
