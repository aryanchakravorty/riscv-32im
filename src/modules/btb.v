`timescale 1ns/1ps

module btb #(
    parameter ENTRIES = 16
)(
    input               clk,
    input               reset,  // active-low
    input               stall,

    // Lookup
    input  [31:0]       lookup_pc,
    output reg          btb_hit,
    output reg          btb_predicted_taken,
    output reg [31:0]   btb_target,
    output              btb_hit_comb_out,
    output              btb_predicted_taken_comb_out,
    output [31:0]       btb_target_comb_out,

    // Update
    input               btb_update_en,
    input  [31:0]       btb_update_pc,
    input               btb_actual_taken,
    input  [31:0]       btb_actual_target
);

localparam INDEX_BITS = $clog2(ENTRIES);
localparam TAG_BITS   = 32 - INDEX_BITS - 2;

reg [ENTRIES-1:0]         valid_array;
reg [TAG_BITS-1:0]        tag_array    [0:ENTRIES-1];
reg [31:0]                target_array [0:ENTRIES-1];
reg [1:0]                 counter_array[0:ENTRIES-1];

wire [INDEX_BITS-1:0] lookup_index = lookup_pc[(INDEX_BITS+1):2];
wire [TAG_BITS-1:0]   lookup_tag   = lookup_pc[31:(INDEX_BITS+2)];

wire                   lookup_valid         = valid_array[lookup_index];
wire [TAG_BITS-1:0]    lookup_entry_tag     = tag_array[lookup_index];
wire [31:0]            lookup_entry_target  = target_array[lookup_index];
wire [1:0]             lookup_entry_counter = counter_array[lookup_index];

wire lookup_hit_comb   = lookup_valid && (lookup_entry_tag == lookup_tag);
wire lookup_taken_comb = lookup_hit_comb && lookup_entry_counter[1];
assign btb_hit_comb_out = lookup_hit_comb;
assign btb_predicted_taken_comb_out = lookup_taken_comb;
assign btb_target_comb_out = lookup_hit_comb ? lookup_entry_target : 32'h0;

wire [INDEX_BITS-1:0] update_index = btb_update_pc[(INDEX_BITS+1):2];
wire [TAG_BITS-1:0]   update_tag   = btb_update_pc[31:(INDEX_BITS+2)];
wire [1:0]            update_counter_cur = counter_array[update_index];

reg [1:0] update_counter_next;
integer i;

always @(*) begin
    update_counter_next = update_counter_cur;
    if (btb_actual_taken) begin
        if (update_counter_cur != 2'b11)
            update_counter_next = update_counter_cur + 2'b01;
    end
    else begin
        if (update_counter_cur != 2'b00)
            update_counter_next = update_counter_cur - 2'b01;
    end
end

always @(posedge clk or negedge reset) begin
    if (!reset) begin
        valid_array <= {ENTRIES{1'b0}};
        btb_hit <= 1'b0;
        btb_predicted_taken <= 1'b0;
        btb_target <= 32'h0;
        for (i = 0; i < ENTRIES; i = i + 1) begin
            tag_array[i] <= {TAG_BITS{1'b0}};
            target_array[i] <= 32'h0;
            counter_array[i] <= 2'b01;
        end
    end
    else begin
        if (btb_update_en) begin
            valid_array[update_index] <= 1'b1;
            tag_array[update_index] <= update_tag;
            target_array[update_index] <= btb_actual_target;
            counter_array[update_index] <= update_counter_next;
        end

        if (!stall) begin
            btb_hit <= lookup_hit_comb;
            btb_predicted_taken <= lookup_taken_comb;
            btb_target <= lookup_hit_comb ? lookup_entry_target : 32'h0;
        end
    end
end

endmodule
