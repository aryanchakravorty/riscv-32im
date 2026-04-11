`timescale 1ns/1ps

module pipe
#(
    parameter [31:0] RESET = 32'h0000_0000
) (
    input               clk,
    input               reset,
    input               stall,
    output              exception,
    output [31:0]       pc_out,
    output [31:0]       alu_result_dbg
);

`include "opcode.vh"

wire stall_if, stall_id, stall_ex, stall_mem;
wire flush_if, flush_id, flush_ex, flush_mem;
wire branch_taken;
wire fetch_redirect_taken;
wire load_use_hazard;
wire id_is_m_ext;
wire id_is_fpu_ext;
wire [4:0] id_fpu_op;

wire [31:0] icache_instruction;
wire        icache_stall;
wire [31:0] icache_mem_addr;
wire        icache_mem_read;
wire [31:0] icache_mem_data;
wire        icache_mem_ready;

wire [31:0] dcache_addr;
wire [31:0] dcache_wdata;
wire [3:0]  dcache_wstrobe;
wire        dcache_read_en;
wire        dcache_write_en;
wire [31:0] dcache_read_data;
wire        dcache_stall;
wire [31:0] dcache_mem_addr;
wire [31:0] dcache_mem_wdata;
wire [3:0]  dcache_mem_wstrobe;
wire        dcache_mem_read;
wire        dcache_mem_write;
wire [31:0] dcache_mem_rdata;
wire        dcache_mem_ready;
wire [31:0] dcache_hit_count;
wire [31:0] dcache_miss_count;
wire [31:0] dcache_writeback_count;

wire [31:0] if_pc, if_pc_plus4, if_instruction;
wire if_valid;
wire if_predicted_taken, id_predicted_taken, ex_predicted_taken;
wire [31:0] if_btb_target, id_btb_target, ex_btb_target;
wire [31:0] if_btb_pc, id_btb_pc, ex_btb_pc;
wire mispredict;

wire        btb_update_en;
wire [31:0] btb_update_pc;
wire        btb_actual_taken;
wire [31:0] btb_actual_target;

wire [31:0] id_pc, id_pc_plus4, id_rs1_data, id_rs2_data, id_immediate;
wire [4:0]  id_rs1_addr, id_rs2_addr, id_rd_addr;
wire [6:0]  id_opcode;
wire [2:0]  id_funct3;
wire        id_funct7_bit5, id_alu_src, id_mem_write, id_mem_read, id_mem_to_reg, id_reg_write;
wire        id_branch, id_jal, id_jalr, id_lui, id_auipc, id_valid;
wire [4:0]  decode_rs1_addr, decode_rs2_addr;

wire [31:0] ex_pc_plus4, ex_alu_result, ex_rs2_data;
wire [4:0]  ex_rd_addr, ex_rs1_addr, ex_rs2_addr;
wire [2:0]  ex_funct3;
wire        ex_is_fpu_ext;
wire [4:0]  ex_fpu_op;
wire        ex_mem_write, ex_mem_read, ex_mem_to_reg, ex_reg_write, ex_valid, ex_stall_out;
wire [31:0] branch_target;
wire [31:0] fetch_redirect_target;
wire        branch_resolved;

wire [31:0] mem_pc_plus4, mem_alu_result, mem_read_data, mem_forward_data;
wire [4:0]  mem_rd_addr;
wire [2:0]  mem_funct3;
wire        mem_is_fpu_ext;
wire [4:0]  mem_fpu_op;
wire        mem_mem_to_reg, mem_reg_write, mem_valid;

wire        wb_reg_write_en;
wire [4:0]  wb_rd_addr;
wire [31:0] wb_rd_data, wb_forward_data;

wire [31:0] reg_rdata1, reg_rdata2;

reg [31:0] regs [0:31];
integer i;
always @(posedge clk or negedge reset) begin
    if (!reset) begin
        for (i = 0; i < 32; i = i + 1) regs[i] <= 32'b0;
    end else if (wb_reg_write_en && (wb_rd_addr != 5'd0)) begin
        regs[wb_rd_addr] <= wb_rd_data;
    end
end

assign reg_rdata1 = (decode_rs1_addr == 5'd0) ? 32'd0 :
                    (wb_reg_write_en && (wb_rd_addr == decode_rs1_addr)) ? wb_rd_data : regs[decode_rs1_addr];
assign reg_rdata2 = (decode_rs2_addr == 5'd0) ? 32'd0 :
                    (wb_reg_write_en && (wb_rd_addr == decode_rs2_addr)) ? wb_rd_data : regs[decode_rs2_addr];

reg [1:0] forward_sel_a, forward_sel_b;
always @(*) begin
    forward_sel_a = 2'b00;
    forward_sel_b = 2'b00;
    if (ex_reg_write && ex_valid && (ex_rd_addr != 0)) begin
        if (ex_rd_addr == id_rs1_addr) forward_sel_a = 2'b10;
        if (ex_rd_addr == id_rs2_addr) forward_sel_b = 2'b10;
    end
    if (mem_reg_write && mem_valid && (mem_rd_addr != 0)) begin
        if (mem_rd_addr == id_rs1_addr && forward_sel_a == 2'b00) forward_sel_a = 2'b01;
        if (mem_rd_addr == id_rs2_addr && forward_sel_b == 2'b00) forward_sel_b = 2'b01;
    end
end

wire decode_is_fpu = if_valid && (if_instruction[`OPCODE] == FPU);
wire decode_fpu_uses_rs2 = decode_is_fpu &&
                           (if_instruction[`FUNC7] != 7'b1100000) &&
                           (if_instruction[`FUNC7] != 7'b1101000);
wire load_use_hazard_base = id_mem_read && id_valid && !decode_is_fpu &&
                            ((id_rd_addr == decode_rs1_addr) || (id_rd_addr == decode_rs2_addr)) &&
                            (id_rd_addr != 5'd0);
wire load_use_hazard_fpu = id_mem_read && id_valid && decode_is_fpu &&
                           (id_rd_addr != 5'd0) &&
                           ((id_rd_addr == decode_rs1_addr) ||
                            (decode_fpu_uses_rs2 && (id_rd_addr == decode_rs2_addr)));
assign load_use_hazard = load_use_hazard_base || load_use_hazard_fpu;

assign stall_if  = stall || load_use_hazard || ex_stall_out || icache_stall || dcache_stall;
assign stall_id  = stall || ex_stall_out || icache_stall || dcache_stall;
assign stall_ex  = stall || ex_stall_out || icache_stall || dcache_stall;
assign stall_mem = stall || dcache_stall;

assign flush_if  = mispredict;
assign flush_id  = mispredict || load_use_hazard;
assign flush_ex  = 1'b0;
assign flush_mem = 1'b0;

fetch u_fetch (
    .clk(clk),
    .reset(reset),
    .stall(stall_if),
    .flush(flush_if),
    .branch_taken(fetch_redirect_taken),
    .branch_target(fetch_redirect_target),
    .btb_update_en(btb_update_en),
    .btb_update_pc(btb_update_pc),
    .btb_actual_taken(btb_actual_taken),
    .btb_actual_target(btb_actual_target),
    .imem_data(icache_instruction),
    .imem_stall(icache_stall),
    .pc_out(if_pc),
    .pc_plus4_out(if_pc_plus4),
    .instruction_out(if_instruction),
    .valid_out(if_valid),
    .current_pc(pc_out),
    .predicted_taken_out(if_predicted_taken),
    .btb_target_out(if_btb_target),
    .btb_pc_out(if_btb_pc)
);

icache u_icache (
    .clk(clk),
    .rst(reset),
    .pc(pc_out),
    .read_en(1'b1),
    .instruction(icache_instruction),
    .stall(icache_stall),
    .mem_addr(icache_mem_addr),
    .mem_read(icache_mem_read),
    .mem_data(icache_mem_data),
    .mem_ready(icache_mem_ready)
);

imem_model #(
    .LATENCY(10)
) u_imem (
    .clk(clk),
    .rst(reset),
    .addr(icache_mem_addr),
    .read_en(icache_mem_read),
    .data(icache_mem_data),
    .ready(icache_mem_ready)
);

decode u_decode (
    .clk(clk),
    .reset(reset),
    .stall(stall_id),
    .flush(flush_id),
    .pc_in(if_pc),
    .pc_plus4_in(if_pc_plus4),
    .instruction_in(if_instruction),
    .valid_in(if_valid),
    .predicted_taken_in(if_predicted_taken),
    .btb_target_in(if_btb_target),
    .btb_pc_in(if_btb_pc),
    .reg_rdata1(reg_rdata1),
    .reg_rdata2(reg_rdata2),
    .rs1_addr(decode_rs1_addr),
    .rs2_addr(decode_rs2_addr),
    .pc_out(id_pc),
    .pc_plus4_out(id_pc_plus4),
    .rs1_data_out(id_rs1_data),
    .rs2_data_out(id_rs2_data),
    .immediate_out(id_immediate),
    .rs1_addr_out(id_rs1_addr),
    .rs2_addr_out(id_rs2_addr),
    .rd_addr_out(id_rd_addr),
    .opcode_out(id_opcode),
    .funct3_out(id_funct3),
    .funct7_bit5_out(id_funct7_bit5),
    .alu_src_out(id_alu_src),
    .mem_write_out(id_mem_write),
    .mem_read_out(id_mem_read),
    .mem_to_reg_out(id_mem_to_reg),
    .reg_write_out(id_reg_write),
    .branch_out(id_branch),
    .jal_out(id_jal),
    .jalr_out(id_jalr),
    .lui_out(id_lui),
    .auipc_out(id_auipc),
    .is_m_ext_out(id_is_m_ext),
    .is_fpu_ext_out(id_is_fpu_ext),
    .fpu_op_out(id_fpu_op),
    .predicted_taken_out(id_predicted_taken),
    .btb_target_out(id_btb_target),
    .btb_pc_out(id_btb_pc),
    .valid_out(id_valid)
);

execute u_execute (
    .clk(clk),
    .reset(reset),
    .stall(stall_ex),
    .flush(flush_ex),
    .pc_in(id_pc),
    .pc_plus4_in(id_pc_plus4),
    .rs1_data_in(id_rs1_data),
    .rs2_data_in(id_rs2_data),
    .immediate_in(id_immediate),
    .rs1_addr_in(id_rs1_addr),
    .rs2_addr_in(id_rs2_addr),
    .rd_addr_in(id_rd_addr),
    .opcode_in(id_opcode),
    .funct3_in(id_funct3),
    .funct7_bit5_in(id_funct7_bit5),
    .alu_src_in(id_alu_src),
    .mem_write_in(id_mem_write),
    .mem_read_in(id_mem_read),
    .mem_to_reg_in(id_mem_to_reg),
    .reg_write_in(id_reg_write),
    .branch_in(id_branch),
    .jal_in(id_jal),
    .jalr_in(id_jalr),
    .lui_in(id_lui),
    .auipc_in(id_auipc),
    .is_m_ext_in(id_is_m_ext),
    .is_fpu_ext_in(id_is_fpu_ext),
    .fpu_op_in(id_fpu_op),
    .valid_in(id_valid),
    .predicted_taken_in(id_predicted_taken),
    .btb_target_in(id_btb_target),
    .btb_pc_in(id_btb_pc),
    .forward_ex_mem_data(mem_forward_data),
    .forward_mem_wb_data(wb_forward_data),
    .forward_a(forward_sel_a),
    .forward_b(forward_sel_b),
    .branch_taken(branch_taken),
    .branch_target(branch_target),
    .pc_plus4_out(ex_pc_plus4),
    .alu_result_out(ex_alu_result),
    .rs2_data_out(ex_rs2_data),
    .rd_addr_out(ex_rd_addr),
    .funct3_out(ex_funct3),
    .is_fpu_ext_out(ex_is_fpu_ext),
    .fpu_op_out(ex_fpu_op),
    .mem_write_out(ex_mem_write),
    .mem_read_out(ex_mem_read),
    .mem_to_reg_out(ex_mem_to_reg),
    .reg_write_out(ex_reg_write),
    .predicted_taken_out(ex_predicted_taken),
    .btb_target_out(ex_btb_target),
    .btb_pc_out(ex_btb_pc),
    .valid_out(ex_valid),
    .rs1_addr_out(ex_rs1_addr),
    .rs2_addr_out(ex_rs2_addr),
    .stall_out(ex_stall_out)
);

assign branch_resolved = (id_branch || id_jal || id_jalr) && id_valid && !stall_ex;
assign mispredict = branch_resolved && (
    (branch_taken != id_predicted_taken) ||
    (branch_taken && (branch_target != id_btb_target))
);
assign fetch_redirect_taken  = mispredict;
assign fetch_redirect_target = branch_taken ? branch_target : id_pc_plus4;

assign btb_update_en     = branch_resolved;
assign btb_update_pc     = id_btb_pc;
assign btb_actual_taken  = branch_taken;
assign btb_actual_target = branch_target;

memory u_memory (
    .clk(clk),
    .reset(reset),
    .stall(stall_mem),
    .flush(flush_mem),
    .pc_plus4_in(ex_pc_plus4),
    .alu_result_in(ex_alu_result),
    .rs2_data_in(ex_rs2_data),
    .rd_addr_in(ex_rd_addr),
    .funct3_in(ex_funct3),
    .is_fpu_ext_in(ex_is_fpu_ext),
    .fpu_op_in(ex_fpu_op),
    .mem_write_in(ex_mem_write),
    .mem_read_in(ex_mem_read),
    .mem_to_reg_in(ex_mem_to_reg),
    .reg_write_in(ex_reg_write),
    .valid_in(ex_valid),
    .pc_plus4_out(mem_pc_plus4),
    .alu_result_out(mem_alu_result),
    .mem_read_data_out(mem_read_data),
    .rd_addr_out(mem_rd_addr),
    .funct3_out(mem_funct3),
    .is_fpu_ext_out(mem_is_fpu_ext),
    .fpu_op_out(mem_fpu_op),
    .mem_to_reg_out(mem_mem_to_reg),
    .reg_write_out(mem_reg_write),
    .valid_out(mem_valid),
    .forward_data(mem_forward_data),
    .dcache_read_data(dcache_read_data),
    .dcache_stall(dcache_stall),
    .dcache_addr(dcache_addr),
    .dcache_wdata(dcache_wdata),
    .dcache_wstrobe(dcache_wstrobe),
    .dcache_read_en(dcache_read_en),
    .dcache_write_en(dcache_write_en)
);

dcache u_dcache (
    .clk(clk),
    .rst(reset),
    .addr(dcache_addr),
    .write_data(dcache_wdata),
    .write_strobe(dcache_wstrobe),
    .read_en(dcache_read_en),
    .write_en(dcache_write_en),
    .read_data(dcache_read_data),
    .stall(dcache_stall),
    .mem_addr(dcache_mem_addr),
    .mem_wdata(dcache_mem_wdata),
    .mem_wstrobe(dcache_mem_wstrobe),
    .mem_read(dcache_mem_read),
    .mem_write(dcache_mem_write),
    .mem_rdata(dcache_mem_rdata),
    .mem_ready(dcache_mem_ready),
    .hit_count(dcache_hit_count),
    .miss_count(dcache_miss_count),
    .writeback_count(dcache_writeback_count)
);

dmem_model #(
    .LATENCY(10)
) u_dmem (
    .clk(clk),
    .addr(dcache_mem_addr),
    .wdata(dcache_mem_wdata),
    .wstrobe(dcache_mem_wstrobe),
    .read_en(dcache_mem_read),
    .write_en(dcache_mem_write),
    .rdata(dcache_mem_rdata),
    .ready(dcache_mem_ready)
);

writeback u_writeback (
    .clk(clk),
    .reset(reset),
    .pc_plus4_in(mem_pc_plus4),
    .alu_result_in(mem_alu_result),
    .mem_read_data_in(mem_read_data),
    .rd_addr_in(mem_rd_addr),
    .funct3_in(mem_funct3),
    .is_fpu_ext_in(mem_is_fpu_ext),
    .fpu_op_in(mem_fpu_op),
    .mem_to_reg_in(mem_mem_to_reg),
    .reg_write_in(mem_reg_write),
    .valid_in(mem_valid),
    .reg_write_en(wb_reg_write_en),
    .rd_addr(wb_rd_addr),
    .rd_data(wb_rd_data),
    .forward_data(wb_forward_data)
);

assign alu_result_dbg = mem_alu_result;
assign exception = 1'b0;

wire [31:0] perf_total_cycles, perf_instrs, perf_icstall, perf_dcstall;
wire [31:0] perf_luuse, perf_divstall, perf_br_taken, perf_mispredict;
wire [31:0] perf_ihits, perf_imisses, perf_dhits, perf_dmisses, perf_dwb;

perf_counters u_perf (
    .clk                 (clk),
    .rst                 (reset),
    .instr_retired       (mem_valid && !dcache_stall),
    .icache_stall        (icache_stall),
    .dcache_stall        (dcache_stall),
    .load_use_stall      (load_use_hazard),
    .div_stall           (ex_stall_out),
    .branch_taken        (branch_taken),
    .mispredict          (mispredict),
    .icache_hit          (u_icache.hit_pulse),
    .icache_miss         (u_icache.miss_pulse),
    .dcache_hit          (u_dcache.hit_pulse),
    .dcache_miss         (u_dcache.miss_pulse),
    .dcache_writeback    (u_dcache.writeback_pulse),
    .total_cycles        (perf_total_cycles),
    .instrs_retired      (perf_instrs),
    .icache_stall_cycles (perf_icstall),
    .dcache_stall_cycles (perf_dcstall),
    .load_use_stall_cycles(perf_luuse),
    .div_stall_cycles    (perf_divstall),
    .branch_taken_count  (perf_br_taken),
    .mispredict_count    (perf_mispredict),
    .icache_hits         (perf_ihits),
    .icache_misses       (perf_imisses),
    .dcache_hits         (perf_dhits),
    .dcache_misses       (perf_dmisses),
    .dcache_writebacks   (perf_dwb)
);

endmodule
