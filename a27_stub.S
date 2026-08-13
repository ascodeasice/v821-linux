/*
 * V821 A27 entry stub. The E907 (via xfel's BROM access) writes this address to
 * CPUX_START_ADD_REG and releases the A27; the A27 begins here in M-mode, does
 * T-Head core-init, and jumps to OpenSBI@0x80000000. Loaded at 0x83f00000.
 * Markers: '#' alive | 'X' mxstatus | 'Y' mcache_ctl | 'W' mmisc_ctl | 'V' pre-jump.
 */
	.section .text.start, "ax"
	.global _start
	.macro TMK ch
	li	t3, 0x42500000
.Ltmk\@:
	lw	t4, 20(t3)
	andi	t4, t4, 0x20
	beqz	t4, .Ltmk\@
	li	t4, \ch
	sw	t4, 0(t3)
	.endm
_start:
	csrw	mie, zero
	TMK	'#'			/* A27 alive */
	/* NOTE: the A27 is Andes, not T-Head -- do NOT write 0x7c0 (that is the E907's
	 * T-Head mxstatus; on the Andes A27 it's a different reg and faults). The A27's
	 * own early-init (board.c andes_harts_early_init) only sets mcache_ctl/mmisc_ctl. */
	li	t0, 0xa701
	csrs	0x7ca, t0		/* mcache_ctl (Andes A27) */
	TMK	'Y'
	li	t0, 0x100
	csrs	0x7d0, t0		/* mmisc_ctl */
	TMK	'W'
	fence.i
	TMK	'V'			/* about to jump to OpenSBI */
	csrr	a0, mhartid
	li	a1, 0
	li	t0, 0x80000000
	jr	t0
