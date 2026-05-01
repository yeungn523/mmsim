# mmsim — Cornell ECE 5760 Final Project

![Verilog](https://img.shields.io/badge/Verilog-HDL-blue?labelColor=grey)
![Board](https://img.shields.io/badge/Board-Terasic%20DE1--SoC-orange?labelColor=grey)
![FPGA](https://img.shields.io/badge/FPGA-Cyclone%20V%205CSEMA5F31C6-orange?labelColor=grey)
![Quartus](https://img.shields.io/badge/Quartus%20Prime%20Lite-18.1-green?labelColor=grey)
![ModelSim](https://img.shields.io/badge/ModelSim%20ASE-18.1-green?labelColor=grey)

___

## Detailed Description

This project implements a **hardware-accelerated stochastic market microstructure simulator**. 
The design synthesizes realistic order flow by combining hardware Geometric Brownian Motion (GBM) price evolution, 
Gaussian random number generation, pseudo-random LFSR seeding, and multiple agent archetypes (noise, market-maker,
momentum, value). Resulting orders are fed through a pipelined matching engine that maintains
a limit order book. The system targets the Terasic DE1-SoC development board (Intel Cyclone V 5CSEMA5F31C6 FPGA), and is synthesized with Intel Quartus Prime Lite 18.1. Each
Verilog block is paired with a Python golden model and a ModelSim testbench so behavior
can be verified deterministically before hardware deployment.

A more detailed write-up of the project can be found here: [View on Github](https://github.com/yeungn523/mmsim_website).
___

## Features

- Pipelined matching engine with three-stage Accept/Match/Commit flow over a 480-tick limit
  order book.
- Time-multiplexed agent execution unit that round-robins through up to 64 agent parameter
  slots backed by M10K blocks.
- Ziggurat-based Gaussian random number generator and a log-space Geometric Brownian Motion
  core driving the price process. Central Limit Theorem and Euler variants are also included
  for comparison purposes only and are not part of the deployed datapath.
- Python golden models and ModelSim TCL pipelines for every RTL submodule.
- DE1-SoC top-level integration with HEX display readout of the last executed price.

___

## Table of Contents

- [mmsim — Cornell ECE 5760 Final Project](#mmsim--cornell-ece-5760-final-project)
  - [Detailed Description](#detailed-description)
  - [Features](#features)
  - [Table of Contents](#table-of-contents)
  - [Dependencies](#dependencies)
  - [Installation](#installation)
  - [Usage](#usage)
    - [Layout](#layout)
    - [Packet Format](#packet-format)
    - [Running Simulations](#running-simulations)
  - [Authors](#authors)
  - [License](#license)

___

## Dependencies

This project requires the following external tools to be installed on the system:

- [Intel Quartus Prime Lite 18.1](https://www.intel.com/content/www/us/en/software-kit/665990/intel-quartus-prime-lite-edition-design-software-version-18-1-for-windows.html)
  for synthesis and bitstream generation targeting the Cyclone V 5CSEMA5F31C6 on the Terasic
  DE1-SoC.
- [Intel ModelSim ASE 18.1](https://www.intel.com/content/www/us/en/software-kit/750368/modelsim-intel-fpgas-standard-edition-software-version-18-1.html)
  for RTL simulation. The project's PowerShell setup script expects ModelSim at
  `C:\programs\intelFPGA\18.1\modelsim_ase\win32aloem`.
- [Python 3.11+](https://www.python.org/downloads/) for the golden model verification scripts.
- The [click](https://click.palletsprojects.com/) package for the Python verification CLIs (see
  [Installation](#installation)).

___

## Installation

This project is distributed as source only. There is no PyPI package or precompiled bitstream.

1. Clone the repository into a local working directory.

2. **Configure the local Windows environment for ModelSim and Python imports.** The repository
   includes a `setup.ps1` PowerShell script that prepends the ModelSim binary directory to `PATH`
   and points `PYTHONPATH` at `src/` so the `mmsim` package resolves correctly. Open the script
   and update the two hard-coded paths to match the local clone location and ModelSim install
   directory, then dot-source it at the start of every PowerShell session used for simulation:

   ```
   . .\setup.ps1
   ```

   ***Note,*** dot-sourcing applies the changes to the current shell; running `.\setup.ps1`
   directly loses them when the child shell exits.

3. **Create the `mmsim` conda environment for Python verification.**

   ```
   conda env create -f environment.yml
   conda activate mmsim
   ```

   ***Note,*** activate `mmsim` ***before*** dot-sourcing `setup.ps1` so the conda Python sits
   ahead of any other interpreter on `PATH`.

___

## Usage

### Layout

Each hardware block lives in its own subfolder under `src/mmsim/` and follows
the same four-directory layout:

```
<block>/
├── rtl/                  # Verilog HDL source for synthesis
├── sim/                  # ModelSim TCL scripts (and CSV stimulus where used)
├── tb/                   # Verilog testbenches
└── python_verification/  # Python golden models and Click CLIs
```

Per-block contents:

- **`agents/`** — Time-multiplexed agent execution unit driving noise,
  market-maker, momentum, and value strategies from M10K-backed parameter
  slots.
- **`gaussian/`** — Ziggurat and CLT-12 Gaussian random number generators;
  shared Ziggurat lookup tables sit under `rtl/lut/`.
- **`gbm/`** — Log-space and Euler Geometric Brownian Motion price evolution
  cores; `rtl/lut/` holds the `exp()` LUT and its generator.
- **`lfsr/`** — Galois LFSR pseudo-random source used to seed the Gaussian
  and agent blocks.
- **`matching_engine/`** — Pipelined Accept/Match/Commit matching engine and
  price-level store backing the 480-tick limit order book; `sim/` carries the
  CSV stimulus and expected-trade vectors used by the regression CLIs.
- **`order_generation/`** — Order FIFO, round-robin arbiter, and
  `order_gen_top` that fans agent output into the matching engine.
- **`top_level/`** — DE1-SoC integration wrapper and full-system testbench.
- **`vga_display/`** — VGA visualization for the live system.
- **`utilities/`** — Shared Python helpers used by all verification CLIs.

### Packet Format

The simulator passes orders between blocks as a 32-bit packet written into the arbiter FIFO:

| Bits      | Field        | Description                                            |
|-----------|--------------|--------------------------------------------------------|
| `[31]`    | `side`       | `0` = buy, `1` = sell                                  |
| `[30]`    | `order_type` | `0` = limit, `1` = market                              |
| `[29:28]` | `agent_type` | `00` = noise, `01` = mm, `10` = momentum, `11` = value |
| `[27:25]` | `reserved`   | `0`                                                    |
| `[24:16]` | `price`      | 9-bit tick index (0-479, direct LOB address)           |
| `[15:0]`  | `volume`     | unsigned 16-bit                                        |

### Running Simulations

Each RTL block includes a ModelSim TCL script under its `sim/` directory. Once `setup.ps1` is
dot-sourced, invoke `vsim` directly against the appropriate TCL script. The matching engine and
price-level-store flows are wrapped by Python Click CLIs that orchestrate the
golden-model -> ModelSim -> CSV-comparison pipeline:

```
python -m mmsim.matching_engine.python_verification.run_matching_engine_csv --stress 1000
python -m mmsim.matching_engine.python_verification.run_price_level_store_no_cancellation_csv
```

___

## Authors

- Natalie Yeung ([yeungn523](https://github.com/yeungn523))
- Guillaume Ah-Hot ([GuillaumeAhhot](https://github.com/GuillaumeAhhot))

___

## License

This project is licensed under the Apache 2.0 License: see the [LICENSE](LICENSE) file for
details.
