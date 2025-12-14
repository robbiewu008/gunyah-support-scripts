#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Best-effort DTB sanity checker for the RPi5 (BCM2712) Gunyah port.
#
# Usage:
#   gunyah-support-scripts/rpi5/check_dtb.sh /path/to/bcm2712-rpi-5-b.dtb
#
# It tries to resolve the active console UART from /chosen stdout-path and
# /aliases, then prints its base address. It also searches for a GIC node and
# prints the first reg base(s) it finds.

set -euo pipefail

DTB="${1:-}"
if [[ -z "${DTB}" || ! -f "${DTB}" ]]; then
	echo "usage: $0 /path/to/bcm2712-rpi-5-b.dtb" >&2
	exit 2
fi

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing required tool: $1" >&2
		exit 1
	fi
}

need_cmd fdtget
need_cmd fdtdump

u64_hex() {
	printf "0x%016x\n" "$1"
}

cells_to_u64() {
	# Convert 1- or 2-cell big-endian u32 list to u64.
	# (Sufficient for BCM2712 addresses.)
	local n="$1"
	shift
	if [[ "${n}" -eq 1 ]]; then
		echo "$((16#${1}))"
	elif [[ "${n}" -eq 2 ]]; then
		echo "$((((16#${1}) << 32) | (16#${2})))"
	else
		echo "unsupported cell count: ${n}" >&2
		return 1
	fi
}

get_u32_cells() {
	local node="$1" prop="$2"
	# fdtget prints cells space-separated on a single line; normalize to 1 per line
	# so callers can safely `mapfile` into arrays.
	fdtget -t x "${DTB}" "${node}" "${prop}" 2>/dev/null | tr ' ' '\n' || true
}

get_u32() {
	local node="$1" prop="$2" def="$3"
	local out
	out="$(fdtget -t x "${DTB}" "${node}" "${prop}" 2>/dev/null || true)"
	if [[ -z "${out}" ]]; then
		echo "${def}"
	else
		echo "$((16#${out}))"
	fi
}

parent_node() {
	local node="$1"
	if [[ "${node}" == "/" ]]; then
		echo "/"
		return 0
	fi
	echo "${node%/*}"
}

translate_addr() {
	# Translate an address in child bus space to parent bus space using `ranges`.
	# If no ranges match, returns the original address.
	local bus="$1"
	local child_addr="$2"

	local bus_addr_cells bus_size_cells parent_addr_cells
	bus_addr_cells="$(get_u32 "${bus}" "#address-cells" 2)"
	bus_size_cells="$(get_u32 "${bus}" "#size-cells" 1)"
	parent_addr_cells="$(get_u32 "$(parent_node "${bus}")" "#address-cells" 2)"

	mapfile -t ranges < <(get_u32_cells "${bus}" ranges)
	if [[ "${#ranges[@]}" -eq 0 ]]; then
		echo "${child_addr}"
		return 0
	fi

	local entry_cells=$((bus_addr_cells + parent_addr_cells + bus_size_cells))
	local i=0
	while [[ $((i + entry_cells)) -le "${#ranges[@]}" ]]; do
		local child_base parent_base size
		local off_child="${i}"
		local off_parent=$((i + bus_addr_cells))
		local off_size=$((i + bus_addr_cells + parent_addr_cells))

		child_base="$(cells_to_u64 "${bus_addr_cells}" "${ranges[@]:off_child:bus_addr_cells}")"
		parent_base="$(cells_to_u64 "${parent_addr_cells}" "${ranges[@]:off_parent:parent_addr_cells}")"
		size="$(cells_to_u64 "${bus_size_cells}" "${ranges[@]:off_size:bus_size_cells}")"

		if [[ "${child_addr}" -ge "${child_base}" && "${child_addr}" -lt "$((child_base + size))" ]]; then
			echo "$((parent_base + (child_addr - child_base)))"
			return 0
		fi
		i=$((i + entry_cells))
	done

	echo "${child_addr}"
}

stdout_path="$(fdtget -t s "${DTB}" /chosen stdout-path 2>/dev/null || true)"
if [[ -z "${stdout_path}" ]]; then
	stdout_path="$(fdtget -t s "${DTB}" /chosen linux,stdout-path 2>/dev/null || true)"
fi

echo "DTB: ${DTB}"
echo "stdout-path: ${stdout_path:-<none>}"

uart_node=""
if [[ "${stdout_path}" == serial* ]]; then
	alias_name="${stdout_path%%:*}"
	uart_node="$(fdtget -t s "${DTB}" /aliases "${alias_name}" 2>/dev/null || true)"
elif [[ "${stdout_path}" == /* ]]; then
	uart_node="${stdout_path%%:*}"
fi

if [[ -n "${uart_node}" ]]; then
	bus_node="$(parent_node "${uart_node}")"
	addr_cells="$(get_u32 "${bus_node}" "#address-cells" 2)"
	size_cells="$(get_u32 "${bus_node}" "#size-cells" 1)"
	mapfile -t uart_reg < <(get_u32_cells "${uart_node}" reg)
	if [[ "${#uart_reg[@]}" -ge $((addr_cells + size_cells)) ]]; then
		uart_child_base="$(cells_to_u64 "${addr_cells}" "${uart_reg[@]:0:addr_cells}")"
		uart_child_size="$(cells_to_u64 "${size_cells}" "${uart_reg[@]:addr_cells:size_cells}")"
		uart_phys_base="$(translate_addr "${bus_node}" "${uart_child_base}")"
		echo "UART node:  ${uart_node}"
		echo "UART reg:   child=$(u64_hex "${uart_child_base}") size=$(u64_hex "${uart_child_size}")"
		echo "UART phys:  $(u64_hex "${uart_phys_base}")"
	else
		echo "UART node:  ${uart_node}"
		echo "UART base: <unavailable: reg not found>"
	fi
else
	echo "UART node: <unresolved>"
fi

echo
echo "Searching GIC node..."

find_gic_node() {
	# Prefer common BCM2712/RPi5 path(s).
	local candidates=(
		"/soc@107c000000/interrupt-controller@7fff9000"
		"/soc/interrupt-controller@7fff9000"
		"/interrupt-controller@7fff9000"
	)

	local node
	for node in "${candidates[@]}"; do
		if fdtget -t s "${DTB}" "${node}" compatible >/dev/null 2>&1; then
			echo "${node}"
			return 0
		fi
	done

	return 1
}

gic_node="$(find_gic_node 2>/dev/null || true)"
if [[ -n "${gic_node}" ]]; then
	echo "GIC node:  ${gic_node}"
	bus_node="$(parent_node "${gic_node}")"
	addr_cells="$(get_u32 "${bus_node}" "#address-cells" 2)"
	size_cells="$(get_u32 "${bus_node}" "#size-cells" 1)"
	mapfile -t gic_reg < <(get_u32_cells "${gic_node}" reg)
	if [[ "${#gic_reg[@]}" -ge $((addr_cells + size_cells)) ]]; then
		i=0
		region=0
		while [[ $((i + addr_cells + size_cells)) -le "${#gic_reg[@]}" ]]; do
			off_base="${i}"
			off_size=$((i + addr_cells))
			gic_child_base="$(cells_to_u64 "${addr_cells}" "${gic_reg[@]:off_base:addr_cells}")"
			gic_child_size="$(cells_to_u64 "${size_cells}" "${gic_reg[@]:off_size:size_cells}")"
			gic_phys_base="$(translate_addr "${bus_node}" "${gic_child_base}")"
			echo "GIC reg[${region}]: child=$(u64_hex "${gic_child_base}") size=$(u64_hex "${gic_child_size}") phys=$(u64_hex "${gic_phys_base}")"
			i=$((i + addr_cells + size_cells))
			region=$((region + 1))
		done
	fi
	exit 0
fi

echo "No /aliases gicv2; falling back to compatible scan (fdtdump)..."

gic_info="$(
	fdtdump -s "${DTB}" | awk '
	BEGIN { in_node=0; path=""; compat=""; reg="" }
	/^[[:space:]]*\/.*\{$/ {
		in_node=1
		path=$0
		sub(/^[[:space:]]*/, "", path)
		sub(/[[:space:]]*\{$/, "", path)
		compat=""
		reg=""
		next
	}
	in_node && /compatible[[:space:]]*=/ {
		compat=$0
	}
	in_node && /reg[[:space:]]*=/ {
		reg=$0
	}
	in_node && /^[[:space:]]*\};/ {
		if ((compat ~ /arm,gic/ || compat ~ /gic-/) && reg != "") {
			print path
			print compat
			print reg
			exit 0
		}
		in_node=0
		path=""
		compat=""
		reg=""
	}
	' || true
)"

if [[ -z "${gic_info}" ]]; then
	echo "GIC: <not found>"
	exit 0
fi

echo "${gic_info}"
