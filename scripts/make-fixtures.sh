#!/bin/bash
# Builds the Windows test and benchmark programs in fixtures/ into fixtures/bin with mingw-w64.
set -euo pipefail
cd "$(dirname "$0")/../fixtures"
mkdir -p bin
CC=x86_64-w64-mingw32-gcc
$CC -O2 -Wall -o bin/dx11_clear.exe dx11_clear.c -ld3d11 -ldxgi
$CC -O2 -Wall -o bin/dx12_clear.exe dx12_clear.c -ld3d12 -ldxgi
$CC -O2 -Wall -o bin/dx11_draws.exe dx11_draws.c -ld3d11 -ldxgi
$CC -O2 -Wall -o bin/win32_calls.exe win32_calls.c -lwinmm
$CC -O2 -Wall -o bin/depth_equal.exe depth_equal.c -ld3d11
# The God of War fix as the app builds it (project.yml), for smoke.sh.
$CC -O2 -Wall -s -shared -o bin/depth-equal-fix.dll ../tools/depth-equal-fix/depth-equal-fix.c ../tools/depth-equal-fix/d3d11.def
ls -la bin
