# RV32IM Pipeline Processor

## Abstract
This project implements a synthesizable 5-stage RV32IM pipeline in Verilog with RV32M integer multiply/divide support, IEEE-754 single-precision floating-point execution, a 2-way set-associative instruction cache, a write-back/write-allocate data cache, and BTB-based dynamic branch prediction. Measured in Vivado xsim, the latest `tb_bench_all` run reports **Matrix Multiply (4×4): 1521 cycles, 0.83 IPC, 96% D-cache hit rate**; the floating-point Newton kernel converges to **sqrt(2) = 0x3FB504F3 (~1.4142)** in **5 iterations**; and loop-heavy benchmark behavior shows **79% BTB accuracy** (from dedicated MatMul benchmark profiling).

## Architecture
The processor follows a classic 5-stage in-order pipeline:

1. **IF**: PC generation, BTB lookup, and I-cache access.
2. **ID**: decode, immediate generation, register read, and control generation.
3. **EX**: ALU operations, branch resolution, RV32M units, and FPU operations.
4. **MEM**: load/store path through D-cache and memory model interface.
5. **WB**: writeback mux and architectural register commit.

Key design decisions:

1. **2-way I-cache over direct-mapped**: reduces conflict misses in tight loops with overlapping code footprints.
2. **Write-back D-cache over write-through**: lowers external memory traffic by deferring stores until eviction.
3. **2-bit saturating-counter BTB**: standard dynamic predictor with better loop behavior than static not-taken prediction.

## Implemented Extensions

| Feature | Latency | Notes |
|---|---:|---|
| RV32M Multiply | 1 cycle (combinational) | Implemented in `multiplier.v` |
| RV32M Divide | 36 cycles (iterative) | Iterative divider with stall handshake |
| FPU FADD/FSUB | 1 cycle (combinational) | IEEE-754 single precision datapath |
| FPU FMUL | 1 cycle (combinational) | IEEE-754 single precision datapath |
| FPU FDIV | multi-cycle (iterative) | Iterative floating-point divide |
| I-Cache | 1 cycle hit / ~80 cycle miss | 2-way, 32-byte lines, line refill from memory model |
| D-Cache | 1 cycle hit / ~80 cycle miss | 128 sets, write-back + write-allocate |
| BTB | 1 cycle lookup | 2-bit saturating counters |

## Benchmark Results

Latest `tb_bench_all` output (Vivado log):

| Benchmark | Total cycles | IPC | I$ hit% | D$ hit% | Writebacks | BTB accuracy |
|---|---:|---:|---:|---:|---:|---:|
| MatMul (4x4 int) | 1521 | 0.83 | 99%* | 96% | 0* | 79%* |
| Newton (sqrt(2), FPU) | 300 | 0.34 | N/A | 50% | N/A | N/A |
| Strided (32B) | 902 | 0.25 | N/A | 50% | N/A | N/A |

\* `tb_bench_all` currently prints cycles/IPC/D$ statistics directly. I$/writeback/BTB values shown for MatMul are from the dedicated `tb_bench_matmul` performance report in the same simulation log.

## Performance Counter Methodology
`perf_counters.v` uses cycle-accurate event counting with saturating 32-bit counters. Events are provided as single-cycle pulses from the pipeline and cache subsystems (`instr_retired`, `icache_stall`, `dcache_stall`, `load_use_stall`, `div_stall`, `branch_taken`, `mispredict`, `icache_hit/miss`, `dcache_hit/miss`, `dcache_writeback`). `total_cycles` increments every active cycle, and IPC is computed as `instrs_retired / total_cycles`.

## Simulation & Verification
- 40-test regression suite covering arithmetic, memory, control, and ISA corner cases (`tb_pipeline_final.v` / `tb_perf_report.v`)
- Isolated cache verification, including write-back policy tests (`tb_dcache_wb.v`)
- Benchmark harnesses (`tb_bench_all.v`, `tb_bench_matmul.v`, `tb_bench_newton.v`)
- Toolchain: Vivado xsim for simulation and Vivado synthesis/implementation flow

## FPGA Deployment
- Target platform: **Digilent Nexys A7-100T** (`xc7a100tcsg324-1`, from `riscv-32im.xpr`)
- Top-level integration in `top_fpga.v`
- Real-time PC visibility on LEDs
- UART TX telemetry at 115200 baud
- Button-triggered UART transmission (current integration transmits selected 32-bit debug value)

## Repository Structure

```text
riscv-32im/
├─ src/
│  ├─ modules/
│  │  ├─ btb.v
│  │  ├─ dcache.v
│  │  ├─ decode.v
│  │  ├─ divider.v
│  │  ├─ dmem_model.v
│  │  ├─ execute.v
│  │  ├─ fetch.v
│  │  ├─ fpu.v
│  │  ├─ icache.v
│  │  ├─ imem_model.v
│  │  ├─ memory.v
│  │  ├─ multiplier.v
│  │  ├─ perf_counters.v
│  │  ├─ uart_driver.v
│  │  ├─ uart_tx.v
│  │  └─ writeback.v
│  ├─ opcode.vh
│  ├─ pipeline.v
│  └─ top_fpga.v
├─ tb/
│  ├─ tb_bench_all.v
│  ├─ tb_bench_matmul.v
│  ├─ tb_bench_newton.v
│  ├─ tb_dcache_wb.v
│  ├─ tb_newton_c.v
│  ├─ tb_perf_report.v
│  ├─ tb_pipeline_final.v
│  └─ tb_uart.v
├─ sim/
│  ├─ imem.hex
│  ├─ dmem.hex
│  ├─ imem_final.hex
│  ├─ dmem_final.hex
│  ├─ newton_imem.hex
│  └─ pipeline_btb_imem.hex
├─ bench_matmul.hex
├─ bench_newton.hex
├─ bench_strided.hex
├─ dmem_matmul.hex
├─ dmem_newton.hex
├─ dmem_strided.hex
├─ newton.c
├─ startup.s
├─ link.ld
├─ update_project.tcl
└─ riscv-32im.xpr
```
