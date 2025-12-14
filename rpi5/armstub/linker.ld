/* SPDX-License-Identifier: BSD-3-Clause */

ENTRY(_start)

SECTIONS
{
	. = 0x0;

	.text : ALIGN(16) {
		*(.text.boot)
		*(.text*)
	}

	.rodata : ALIGN(16) {
		*(.rodata*)
	}

	.data : ALIGN(16) {
		*(.data*)
	}

	.bss : ALIGN(16) {
		*(.bss*)
		*(COMMON)
	}
}

