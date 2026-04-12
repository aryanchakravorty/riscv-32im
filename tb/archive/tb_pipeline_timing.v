`timescale 1ns/1ps

module tb_pipeline_timing;

    reg clk;
    reg reset;
    reg stall;
    wire exception;
    wire [31:0] pc_out;

    // Instantiate the pipeline
    pipe dut (
        .clk(clk),
        .reset(reset),
        .stall(stall),
        .exception(exception),
        .pc_out(pc_out)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Instruction memory for lookup (for logging)
    reg [31:0] imem [0:1023];
    
    // Improved function to return full instruction strings
    function [255:0] get_instr_str(input [31:0] instr);
        reg [6:0] opcode;
        reg [2:0] f3;
        reg [6:0] f7;
        reg [4:0] rd, rs1, rs2;
        reg [31:0] imm;
        reg [127:0] mnem;
        begin
            opcode = instr[6:0];
            f3 = instr[14:12];
            f7 = instr[31:25];
            rd = instr[11:7];
            rs1 = instr[19:15];
            rs2 = instr[24:20];
            
            if (instr == 32'h0000_0013) get_instr_str = "nop";
            else if (instr == 0) get_instr_str = "bubble";
            else begin
                case (opcode)
                    7'b0110111: begin // LUI
                        imm = {instr[31:12], 12'b0};
                        $swrite(get_instr_str, "lui x%0d, 0x%h", rd, imm);
                    end
                    7'b0010111: begin // AUIPC
                        imm = {instr[31:12], 12'b0};
                        $swrite(get_instr_str, "auipc x%0d, 0x%h", rd, imm);
                    end
                    7'b1101111: begin // JAL
                        imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
                        $swrite(get_instr_str, "jal x%0d, %0d", rd, $signed(imm));
                    end
                    7'b1100111: begin // JALR
                        imm = {{20{instr[31]}}, instr[31:20]};
                        $swrite(get_instr_str, "jalr x%0d, %0d(x%0d)", rd, $signed(imm), rs1);
                    end
                    7'b0000011: begin // LOAD
                        imm = {{20{instr[31]}}, instr[31:20]};
                        $swrite(get_instr_str, "lw x%0d, %0d(x%0d)", rd, $signed(imm), rs1);
                    end
                    7'b0100011: begin // STORE
                        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
                        $swrite(get_instr_str, "sw x%0d, %0d(x%0d)", rs2, $signed(imm), rs1);
                    end
                    7'b0010011: begin // ARITHI
                        imm = {{20{instr[31]}}, instr[31:20]};
                        case (f3)
                            3'b000: mnem = "addi";
                            3'b001: mnem = "slli";
                            3'b010: mnem = "slti";
                            3'b011: mnem = "sltiu";
                            3'b100: mnem = "xori";
                            3'b101: mnem = f7[5] ? "srai" : "srli";
                            3'b110: mnem = "ori";
                            3'b111: mnem = "andi";
                        endcase
                        $swrite(get_instr_str, "%s x%0d, x%0d, %0d", mnem, rd, rs1, $signed(imm));
                    end
                    7'b0110011: begin // ARITHR / M-EXT
                        if (f7 == 7'b0000001) begin
                            case (f3)
                                3'b000: mnem = "mul";
                                3'b001: mnem = "mulh";
                                3'b010: mnem = "mulhsu";
                                3'b011: mnem = "mulhu";
                                3'b100: mnem = "div";
                                3'b101: mnem = "divu";
                                3'b110: mnem = "rem";
                                3'b111: mnem = "remu";
                            endcase
                        end else begin
                            case (f3)
                                3'b000: mnem = f7[5] ? "sub" : "add";
                                3'b001: mnem = "sll";
                                3'b010: mnem = "slt";
                                3'b011: mnem = "sltu";
                                3'b100: mnem = "xor";
                                3'b101: mnem = f7[5] ? "sra" : "srl";
                                3'b110: mnem = "or";
                                3'b111: mnem = "and";
                            endcase
                        end
                        $swrite(get_instr_str, "%s x%0d, x%0d, x%0d", mnem, rd, rs1, rs2);
                    end
                    7'b1100011: begin // BRANCH
                        imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
                        case (f3)
                            3'b000: mnem = "beq";
                            3'b001: mnem = "bne";
                            3'b100: mnem = "blt";
                            3'b101: mnem = "bge";
                            3'b110: mnem = "bltu";
                            3'b111: mnem = "bgeu";
                        endcase
                        $swrite(get_instr_str, "%s x%0d, x%0d, %0d", mnem, rs1, rs2, $signed(imm));
                    end
                    default: $swrite(get_instr_str, "unknown (0x%h)", instr);
                endcase
            end
        end
    endfunction

    integer cycle;
    integer i;
    
    initial begin
        // Load imem lookup table for human-readable logging.
        // DUT instruction memory is already initialized in imem_model.
        $readmemh("imem.hex", imem);
        
        reset = 0;
        stall = 0;
        cycle = 0;
        #15 reset = 1;
        
        $display("\n======================================================================== PIPELINE TIMING LOG ========================================================================");
        $display("%-6s | %-8s | %-20s | %-20s | %-20s | %-20s | %-20s | %-7s | %-4s | %-15s", 
                 "Cycle", "PC", "FETCH", "DECODE", "EXECUTE", "MEMORY", "WRITEBACK", "S:I/D/E", "Fwd", "WB_Result");
        $display("-------|----------|----------------------|----------------------|----------------------|----------------------|----------------------|---------|------|----------------");
        
        // Run for 100 cycles to cover the long DIV stall and branch
        repeat (100) begin
            @(posedge clk);
            #1; // Wait for signals to settle
            
            $write("%-6d | %08h | ", cycle, dut.u_fetch.current_pc);
            
            // FETCH
            $write("%-20s | ", get_instr_str(imem[dut.u_fetch.current_pc[11:2]]));
            
            // DECODE
            $write("%-20s | ", dut.if_valid ? get_instr_str(dut.if_instruction) : "bubble");
            
            // EXECUTE
            $write("%-20s | ", dut.id_valid ? get_instr_str(imem[dut.id_pc >> 2]) : "bubble");
            
            // MEMORY
            $write("%-20s | ", dut.ex_valid ? get_instr_str(imem[(dut.ex_pc_plus4-4) >> 2]) : "bubble");
            
            // WRITEBACK
            $write("%-20s | ", dut.mem_valid ? get_instr_str(imem[(dut.mem_pc_plus4-4) >> 2]) : "bubble");
            
            // Stall/Flush
            $write("S:%b%b%b | ", 
                dut.stall_if, dut.stall_id, dut.stall_ex);
                
            // Forwarding
            $write("%b%b | ", dut.f_a, dut.f_b);
            
            // WB Result
            if (dut.wb_reg_write_en && dut.wb_rd_addr != 0) 
                $write("x%-2d = %08h", dut.wb_rd_addr, dut.wb_rd_data);
            
            $display("");
            cycle = cycle + 1;
        end
        
        $display("=====================================================================================================================================================================\n");
        $finish;
    end

endmodule
