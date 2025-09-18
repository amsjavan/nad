#!/bin/bash

set -e

echo "Building eBPF program with BTF support..."

# Check if clang is available
if ! command -v clang &> /dev/null; then
    echo "Error: clang not found. Please install clang."
    exit 1
fi

# Simple build with BTF debug info
clang -O2 -target bpf -g -c traffic_pump.c -o traffic_pump.o

if [ $? -eq 0 ]; then
    echo "✓ eBPF compilation successful!"
    echo "Output: traffic_pump.o"
    ls -lh traffic_pump.o
    
    # Check if BTF info is present
    if command -v llvm-objdump &> /dev/null; then
        echo "Checking BTF info..."
        llvm-objdump -h traffic_pump.o | grep -E "\.BTF" || echo "No BTF section found"
    fi
    
    # Check sections
    if command -v llvm-objdump &> /dev/null; then
        echo "Program sections:"
        llvm-objdump -h traffic_pump.o
    fi
else
    echo "✗ eBPF compilation failed!"
    exit 1
fi

echo "Build complete!"