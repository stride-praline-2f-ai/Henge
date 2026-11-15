#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/portable
${CC:-cc} -std=c11 -D_POSIX_C_SOURCE=200809L -DHENGE_PORTABLE_TEST \
    -Wall -Wextra -O1 -g -ffunction-sections -fdata-sections \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -Icore -Ihost -Idevices tests/test_fastmem.c core/mmu.c core/fastmem.c \
    -Wl,--gc-sections -o build/portable/test_fastmem
build/portable/test_fastmem
