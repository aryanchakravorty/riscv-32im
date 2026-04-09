# riscv-32im

## Project Overview

`riscv-32im` is a Verilog implementation of a 5-stage RISC-V pipeline (RV32IM-oriented core) for Vivado/Xilinx flow.

The pipeline RTL top is `pipe` in `src/pipeline.v`, and the FPGA top is `top_fpga` in `src/top_fpga.v`.

Pipeline stages:

- IF (Instruction Fetch)
- ID (Instruction Decode / Register Read)
- EX (Execute)
- MEM (Memory Access)
- WB (Write Back)

## Features

- **5-stage pipelined core**
  - Forwarding/bypass paths
  - Hazard detection with stall/flush control
- **RV32M execution units**
  - `multiplier.v`: combinational multiply path
  - `divider.v`: iterative divider/remainder with `start/busy` handshake
- **Caches**
  - **I-cache (`icache.v`)**: 4 KB, 2-way set-associative, 64 sets, 32-byte lines, pseudo-LRU replacement
  - **D-cache (`dcache.v`)**: 2 KB, direct-mapped, 64 sets, 32-byte lines, write-through + no-write-allocate policy
- **Branch Target Buffer (BTB)**
  - 16-entry direct-mapped table
  - 2-bit saturating counters
- **IEEE-754 single-precision FPU (`fpu.v`)**
  - Arithmetic: `FADD`, `FSUB`, `FMUL`, `FDIV`
  - Min/Max and compare: `FMIN`, `FMAX`, `FEQ`, `FLT`, `FLE`
  - Rounding-to-int style ops: floor, ceil, round-to-nearest-even
  - Conversions: `FCVT.W.S`, `FCVT.WU.S`, `FCVT.S.W`, `FCVT.S.WU`

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
│  │  └─ writeback.v
│  ├─ opcode.vh
│  ├─ pipeline.v
│  └─ top_fpga.v
├─ tb/                         # Testbenches
├─ sim/                        # Memory/program images (.hex)
├─ update_project.tcl
└─ riscv-32im.xpr
```

## Vivado Flow

### Simulation

1. Open `riscv-32im.xpr`.
2. In **Simulation Sources**, select a testbench from `tb/` (project default simulation top is `tb_pipeline_timing`).
3. Keep memory images from `sim/` available to simulation runtime.
   - `imem_model.v` loads `imem.hex`
   - `dmem_model.v` loads `dmem.hex` (fallback: `dmem_final.hex`)
4. Run **Behavioral Simulation** (`xsim`).

### Synthesis / Implementation

1. Open `riscv-32im.xpr`.
2. Set top module to `top_fpga`.
3. Run **Synthesis**, **Implementation**, and **Generate Bitstream**.
