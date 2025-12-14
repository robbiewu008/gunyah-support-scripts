// SPDX-License-Identifier: BSD-3-Clause
//
// Minimal Raspberry Pi 5 (BCM2712) armstub replacement for Type-1 payloads.
// This is intended to satisfy the firmware request for "armstub8-2712.bin"
// when using `kernel_old=1` + `kernel_address=...`.
//
// It presents a minimal AArch64 Linux Image-style header so that the firmware
// will accept it, then disables interrupts, sets up a small stack, prints a
// marker, and branches to the payload load address (default: 0x00400000).
//
// Note: The payload is expected to perform its own EL checks and platform init.

	.section .text.boot, "ax"
	.align 11
	.global _start
_start:
	// Minimal Linux arm64 Image header.
	// Layout matches struct arm64_image_header in linux: arch/arm64/include/asm/image.h
	// Firmware typically enters at image base + 0x80.
	.word	0x14000020		// 0x00 code0: b stext (+0x80)
	.word	0xd503201f		// 0x04 code1: nop
	.quad	0			// 0x08 text_offset
	.quad	_end - _start		// 0x10 image_size
	.quad	0			// 0x18 flags
	.quad	0			// 0x20 res2
	.quad	0			// 0x28 res3
	.quad	0			// 0x30 res4
	.word	0x644d5241		// 0x38 magic "ARM\x64"
	.word	0			// 0x3c res5

	// Pad to 0x80 for the entry point.
	.space	0x40

stext:
	// Mask interrupts (best effort).
	msr	daifset, #0xf
	isb

	// Firmware may enter the stub with the MMU enabled and a non-identity
	// mapping. Disable MMU at the current EL so we can safely access
	// physical MMIO (UART) and the payload load address.
	mrs	x15, CurrentEL
	and	x15, x15, #0xc
	cmp	x15, #0xc
	b.eq	1f			// EL3
	cmp	x15, #0x8
	b.eq	2f			// EL2
	cmp	x15, #0x4
	b.eq	3f			// EL1
	b	4f

1:	// EL3
	mrs	x14, SCTLR_EL3
	bic	x14, x14, #1		// M
	msr	SCTLR_EL3, x14
	isb
	b	4f

2:	// EL2
	mrs	x14, SCTLR_EL2
	bic	x14, x14, #1		// M
	msr	SCTLR_EL2, x14
	isb

	// Some firmware paths may leave stage-2 translation enabled (HCR_EL2.VM=1).
	// Disable it so physical MMIO (UART) and the payload LMA are accessible.
	msr	VTCR_EL2, xzr
	msr	VTTBR_EL2, xzr
	msr	HCR_EL2, xzr
	isb
	b	4f

3:	// EL1
	mrs	x14, SCTLR_EL1
	bic	x14, x14, #1		// M
	msr	SCTLR_EL1, x14
	isb

4:
	// If we are still in EL3, drop to non-secure EL2h before continuing.
	// The hypervisor entry checks for EL2 and will spin otherwise.
	mrs	x15, CurrentEL
	and	x15, x15, #0xc
	cmp	x15, #0xc
	b.ne	5f

	mrs	x14, SCR_EL3
	orr	x14, x14, #(1 << 0)	// NS
	orr	x14, x14, #(1 << 8)	// HCE
	orr	x14, x14, #(1 << 10)	// RW (AArch64 for lower ELs)
	msr	SCR_EL3, x14
	isb

	// Ensure EL2 starts with MMU and caches disabled so the payload can
	// safely assume physical addressing (Gunyah expects this).
	mrs	x13, SCTLR_EL2
	bic	x13, x13, #1		// M
	bic	x13, x13, #(1 << 2)	// C
	bic	x13, x13, #(1 << 12)	// I
	msr	SCTLR_EL2, x13
	isb

	// Ensure stage-2 translation is disabled on entry to EL2.
	msr	VTCR_EL2, xzr
	msr	VTTBR_EL2, xzr
	msr	HCR_EL2, xzr
	isb

	// EL2h, mask DAIF.
	mov	x14, #0x3c9		// DAIF=0xf, M=0x9 (EL2h)
	msr	SPSR_EL3, x14
	adr	x14, 4f
	msr	ELR_EL3, x14
	eret

4:
	isb

5:
	// Early UART marker on the board debug console (PL011 @ 0x107D001000).
	// This confirms the stub executed before jumping to the payload.
	movz	x9, #0x1000
	movk	x9, #0x7d00, lsl #16
	movk	x9, #0x0010, lsl #32

	// Print current EL: "EL<digit> ".
	mrs	x15, CurrentEL
	and	x15, x15, #0xc

	// Wait for TX FIFO space (PL011 FR bit 5 = TXFF).
1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, 'E'
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, 'L'
	str	w10, [x9, #0x00]

	lsr	x16, x15, #2
	add	w10, w16, '0'
1:	ldr	w11, [x9, #0x18]
	tst	w11, #0x20
	b.ne	1b
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, ' '
	str	w10, [x9, #0x00]

	// Wait for TX FIFO space (PL011 FR bit 5 = TXFF).
1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, 'S'
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, 'T'
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, 'U'
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, 'B'
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, '\r'
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, '\n'
	str	w10, [x9, #0x00]

	// Set a small temporary stack at 0x00080000.
	movz	x1, #0x8, lsl #16
	mov	sp, x1

	// Dump the first word at the payload load address as hex:
	// "@" + 8 hex digits + "\r\n".
	movz	x4, #0x40, lsl #16	// 0x00400000
	ldr	w5, [x4]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, '@'
	str	w10, [x9, #0x00]

	mov	w6, #28
10:	lsr	w7, w5, w6
	and	w7, w7, #0xf
	cmp	w7, #10
	b.lo	11f
	add	w7, w7, #('a' - 10)
	b	12f
11:	add	w7, w7, #'0'
12:
1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	str	w7, [x9, #0x00]

	subs	w6, w6, #4
	b.pl	10b

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, '\r'
	str	w10, [x9, #0x00]

1:	ldr	w10, [x9, #0x18]
	tst	w10, #0x20
	b.ne	1b
	mov	w10, '\n'
	str	w10, [x9, #0x00]

	// Clear argument registers.
	mov	x0, xzr
	mov	x1, xzr
	mov	x2, xzr
	mov	x3, xzr

	// Jump to the raw payload at 0x00400000 (kernel_address).
	br	x4

1:	wfi
	b	1b

_end:
