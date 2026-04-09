# riscv-32im

## Project Overview

`riscv-32im` is a Verilog implementation of a **5-stage RV32IM RISC-V pipeline** targeting **Xilinx FPGA flow (Vivado)**.

The design includes a complete integer pipeline, RV32M hardware execution units, cache hierarchy, IEEE-754 single-precision floating-point execution, and branch prediction support with a BTB.

Pipeline stages:

- IF (Instruction Fetch)
- ID (Instruction Decode / Register Read)
- EX (Execute)
- MEM (Memory Access)
- WB (Write Back)

## Features

- **5-stage pipelined RV32IM core**
  - Full forwarding/bypass paths
  - Hazard detection and pipeline stall/flush control
- **RV32M support**
  - Multiplier: combinational hardware path
  - Divider: iterative (~32-cycle) unit with `start/busy` handshake
- **L1 instruction + data caches**
  - 4 KB each
  - 2-way set-associative
  - Write-through policy
- **IEEE-754 single-precision FPU**
  - Arithmetic: `FADD`, `FSUB`, `FMUL`, `FDIV`
  - Min/Max: `FMIN`, `FMAX`
  - Compare: `FEQ`, `FLT`, `FLE`
  - Rounding ops: `floor`, `ceil`, round-to-nearest-even integer op
  - Conversions:
    - `FCVT.W.S`, `FCVT.WU.S`
    - `FCVT.S.W`, `FCVT.S.WU`
- **Branch Target Buffer (BTB)**
  - 16-entry direct-mapped structure
  - 2-bit saturating prediction counters
  - PC-indexed lookup/update

## Repository Structure

Logical layout used in this README:

```text
riscv-32im/
├─ src/                         # RTL source tree
│  ├─ modules/                  # Core modules (fetch/decode/execute/memory/writeback, btb, fpu, caches, etc.)
│  ├─ opcode.vh
│  ├─ pipeline.v
│  └─ top_fpga.v
├─ tb/                          # Testbenches
├─ sim/                         # Program/data images used by $readmemh
├─ docs/                        # Architecture notes/diagrams
└─ riscv-32im.xpr               # Vivado project
```

Current project path mapping:

- `src/` → `riscv-32im.srcs/sources_1/imports/5-stage-version/`
- `tb/` → `riscv-32im.srcs/sources_1/imports/5-stage-version/testBenches/`
- `sim/` → repository root (`imem.hex`, `dmem.hex`, `newton_imem.hex`, `pipeline_btb_imem.hex`)
- `docs/` → currently includes `RISCV_Pipeline_Diagrams.txt` (at repo root)

## How to Simulate in Vivado

1. Open the project:

   ```text
   riscv-32im.xpr
   ```

2. In **Simulation Sources**, select a testbench from:

   ```text
   tb/  (mapped to riscv-32im.srcs/sources_1/imports/5-stage-version/testBenches/)
   ```

3. Ensure required memory image files used by `$readmemh` are available to simulation (working dir or project files), for example:

   ```text
   imem.hex
   dmem.hex
   newton_imem.hex
   pipeline_btb_imem.hex
   ```

4. Run **Behavioral Simulation** (`xsim`) from Vivado.

## How to Synthesize

1. Open:

   ```text
   riscv-32im.xpr
   ```

2. Set top module to:

   ```text
   top_fpga
   ```

3. Run Vivado flow:
   - **Run Synthesis**
   - **Run Implementation**
   - **Generate Bitstream**

4. Program the FPGA using Vivado Hardware Manager (with your board constraints configured in the project).
