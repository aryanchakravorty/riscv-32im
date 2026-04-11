`timescale 1ns/1ps

module perf_counters (
    input               clk,
    input               rst,

    input               instr_retired,
    input               icache_stall,
    input               dcache_stall,
    input               load_use_stall,
    input               div_stall,
    input               branch_taken,
    input               mispredict,
    input               icache_hit,
    input               icache_miss,
    input               dcache_hit,
    input               dcache_miss,
    input               dcache_writeback,

    output reg [31:0]   total_cycles,
    output reg [31:0]   instrs_retired,
    output reg [31:0]   icache_stall_cycles,
    output reg [31:0]   dcache_stall_cycles,
    output reg [31:0]   load_use_stall_cycles,
    output reg [31:0]   div_stall_cycles,
    output reg [31:0]   branch_taken_count,
    output reg [31:0]   mispredict_count,
    output reg [31:0]   icache_hits,
    output reg [31:0]   icache_misses,
    output reg [31:0]   dcache_hits,
    output reg [31:0]   dcache_misses,
    output reg [31:0]   dcache_writebacks
);

    localparam [31:0] SAT_MAX = 32'hFFFF_FFFF;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            total_cycles          <= 32'h0;
            instrs_retired        <= 32'h0;
            icache_stall_cycles   <= 32'h0;
            dcache_stall_cycles   <= 32'h0;
            load_use_stall_cycles <= 32'h0;
            div_stall_cycles      <= 32'h0;
            branch_taken_count    <= 32'h0;
            mispredict_count      <= 32'h0;
            icache_hits           <= 32'h0;
            icache_misses         <= 32'h0;
            dcache_hits           <= 32'h0;
            dcache_misses         <= 32'h0;
            dcache_writebacks     <= 32'h0;
        end else begin
            if (total_cycles != SAT_MAX) total_cycles <= total_cycles + 32'd1;

            if (instr_retired        && (instrs_retired        != SAT_MAX)) instrs_retired        <= instrs_retired + 32'd1;
            if (icache_stall         && (icache_stall_cycles   != SAT_MAX)) icache_stall_cycles   <= icache_stall_cycles + 32'd1;
            if (dcache_stall         && (dcache_stall_cycles   != SAT_MAX)) dcache_stall_cycles   <= dcache_stall_cycles + 32'd1;
            if (load_use_stall       && (load_use_stall_cycles != SAT_MAX)) load_use_stall_cycles <= load_use_stall_cycles + 32'd1;
            if (div_stall            && (div_stall_cycles      != SAT_MAX)) div_stall_cycles      <= div_stall_cycles + 32'd1;
            if (branch_taken         && (branch_taken_count    != SAT_MAX)) branch_taken_count    <= branch_taken_count + 32'd1;
            if (mispredict           && (mispredict_count      != SAT_MAX)) mispredict_count      <= mispredict_count + 32'd1;
            if (icache_hit           && (icache_hits           != SAT_MAX)) icache_hits           <= icache_hits + 32'd1;
            if (icache_miss          && (icache_misses         != SAT_MAX)) icache_misses         <= icache_misses + 32'd1;
            if (dcache_hit           && (dcache_hits           != SAT_MAX)) dcache_hits           <= dcache_hits + 32'd1;
            if (dcache_miss          && (dcache_misses         != SAT_MAX)) dcache_misses         <= dcache_misses + 32'd1;
            if (dcache_writeback     && (dcache_writebacks     != SAT_MAX)) dcache_writebacks     <= dcache_writebacks + 32'd1;
        end
    end

endmodule
