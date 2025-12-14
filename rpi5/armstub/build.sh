#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-armstub8-2712.bin}"

CLANG="${CLANG:-clang}"
OBJCOPY="${OBJCOPY:-llvm-objcopy}"

if [[ -n "${LLVM:-}" ]]; then
	CLANG="${LLVM}/bin/clang"
	OBJCOPY="${LLVM}/bin/llvm-objcopy"
fi

"${CLANG}" \
	-target aarch64-none-elf \
	-ffreestanding -nostdlib \
	-Wl,--build-id=none \
	-Wl,-T,"${SCRIPT_DIR}/linker.ld" \
	-o "${SCRIPT_DIR}/armstub8-2712.elf" \
	"${SCRIPT_DIR}/armstub8-2712.S"

"${OBJCOPY}" -O binary "${SCRIPT_DIR}/armstub8-2712.elf" "${OUT}"

echo "Built ${OUT}"

