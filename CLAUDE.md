# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a collection of scripts and utilities primarily focused on FreeBSD system administration, network testing, and benchmarking. The repository contains:

- **FreeBSD/**: Scripts and tools for FreeBSD system administration, jails, benchmarking, and networking
- **network/**: Network testing and monitoring utilities
- **tools/**: General purpose utilities and documentation
- **configs/**: Configuration files for various tools (tmux, vim, csh, etc.)
- **Linux/**, **MacOS/**, **Windows/**: Platform-specific scripts and notes

## Common Development Tasks

### Building C Programs
Several directories contain C programs with Makefiles:
- `FreeBSD/sendfile/`: Network programming test tools
- `FreeBSD/testrss/`: RSS (Receive Side Scaling) testing
- `FreeBSD/tcp_dscp/`: TCP DSCP testing tools
- `FreeBSD/benches/udp/`: UDP benchmarking tools

To build these programs (use BSD make, not GNU make):
```bash
cd FreeBSD/sendfile  # or other directory with Makefile
make
```

### Running Tests
Test scripts are typically named with `_test.sh` suffix:
- `FreeBSD/sendfile/sendfile_test.sh`
- `FreeBSD/tcp_dscp/sendfile_test.sh`

### Benchmarking Scripts
Key benchmarking tools:
- `FreeBSD/benches/tcp/bench-tcp-cca.sh`: TCP stack and congestion control algorithm benchmarking
- `FreeBSD/tmux-bench.sh`: Tmux-based benchmarking setup
- `FreeBSD/benches/buildworld.sh`: FreeBSD buildworld benchmarking

These scripts typically require root privileges and may need specific kernel modules or configuration.

## Architecture Notes

### FreeBSD Focus
The repository is heavily FreeBSD-oriented with emphasis on:
- System performance testing and benchmarking
- Network protocol testing (TCP stacks, congestion control algorithms)
- Jail management and configuration
- ZFS and boot environment management
- Hardware compatibility testing

### Shell Script Conventions
Most scripts follow these patterns:
- Use `set -euo pipefail` for strict error handling
- Include usage/help functions
- Support both interactive and automated execution
- Generate reports in markdown format where applicable

### Jail Management
The `FreeBSD/jail/` directory contains comprehensive jail management scripts for creating, destroying, and configuring FreeBSD jails with various network setups.

## Important Files

- `README.md`: Main repository documentation with links to subdirectories
- `FreeBSD/README.md`: Comprehensive FreeBSD administration guide including building, ZFS, NFS, and system setup
- Individual README files in subdirectories provide specific documentation for tools and benchmarks

## Platform-Specific Notes

- **FreeBSD**: Primary platform with extensive tooling
- **Linux/**: Limited Linux-specific utilities
- **MacOS/**: Cross-compilation notes and utilities
- **Windows/**: Network testing tools and batch scripts
- **network/**: Cross-platform network utilities

When working with this codebase, focus on understanding the FreeBSD-centric architecture and the emphasis on system performance, networking, and administrative automation.