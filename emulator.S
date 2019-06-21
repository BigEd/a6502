/*
 * This file is part of the a6502 project.
 *
 * Copyright (C) 2012 Ed Spittles <ed.spittles@gmail.com>
 *
 * This library is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
6502 emulator in thumb2 assembly

2012-06-11  Ed Spittles  started (as outgrowth of usb_cdcacm example in libopencm3)
  FIXME: 6502 status register modelling incomplete and undecided
  FIXME: (optional?) wrapping of PC and SP; also wrapping in ZP and any other half-word operations
  FIXME: decimal mode, of course

Target is 168MHz cortex m4 (STM32F407VGT6, has 192k of RAM)

Using deeply nested macros - can get visibility for debug using
  arm-none-eabi-gcc -E *.S > x.tmp
  arm-none-eabi-as -amlh=x.list  x.tmp

Try to use ARM's status bits to model the 6502's.
As thumb2 offers conditional update of status bits, we might not even need to keep saving and restoring

As the bits are in different places, and we have no D and I (and of course no B)
When we do save and restore we need to take care of the D and I
We also need a conversion between ARM's positions in a 32-bit word and 6502's order in an 8-bit byte.

r0  operand byte, opcode
r1  effective address
*/

#define rmem    r2  /* memory base pointer   */
#define rPC     r3  /* pc program counter    */
#define rAcc    r4  /* a (accumulator)       */
#define rXreg   r5  /* x index register      */
#define rYreg   r6  /* y index register      */
#define rTrace  r7  /* trace control - could consolidate into rPbyteLo */

#define rSP       r8  /* sp stack pointer      */
#define rPbyteHi  r9  /* Process status byte Hi */ /* bit 31 down is in ARM order: NZCV */
#define rPbyteLo  r10 /* Process status byte Lo */ /* D and I, two stuck bits, in 6502 order: nv-bdizc */
#define rMask24   r11 /* mask for arithmetic fixup */

#define armNflag (0x80<<24)	/* negative NZCV---- */
#define armZflag (0x40<<24)	/* zero     NZCV---- */
#define armCflag (0x20<<24)	/* carry    NZCV---- */
#define armVflag (0x10<<24)	/* overflow NZCV---- */

#define pByteXflag 0x20		/* stuck      nv-bdizc */
#define pByteBflag 0x10		/* break      nv-bdizc */
#define pByteDflag 0x08		/* decimal    nv-bdizc */
#define pByteIflag 0x04		/* interrupt  nv-bdizc */

@  #define rdispatch r7  /* dispatch table useful only if switching instruction sets */

.thumb
.syntax unified
.text

@ convert ARMs Pbyte (NZCV) to 6502 status byte (nv-bdizc) in r0
.macro pByteToR0
	mov     r0, rPbyteLo
	MSR	APSR, rPbyteHi
@	and	r0, #0x3c	@ leave only X, B, D and I - may be redundant
	it mi
	orrmi	r0, #0x80
	it vs
	orrvs	r0, #0x40
	it eq
	orreq	r0, #0x02
	it cs
	orrcs	r0, #0x01
.endm

@ convert from 6502 status byte (nv-bdizc) in r0 to ARMs Pbyte (NZCV)
.macro r0toPByte
	orr	r0, r0, #(pByteXflag|pByteBflag) @ take care of the stuck bits

	tst	r0, #0x80
	it ne
	orrne	r0, #armNflag

	tst	r0, #0x02
	it ne
	orrne	r0, #armZflag

	tst	r0, #0x01
	it ne
	orrne	r0, #armCflag

	tst	r0, #0x40
	it ne
	orrne	r0, #armVflag

	and	rPbyteHi, r0, #0xf0000000
	and	rPbyteLo, r0, #0x0000003c
.endm

@ print cpu state
	.macro print6502state
        push    {r0-r3}  @ could be clobbered
	push	{r0}  @ parameter 7 - IR (probably)
	pByteToR0
	push	{r0}  @ parameter 6 - status byte
	push	{rPC} @ parameter 5
        mov     r0, rAcc
        mov     r1, rXreg
        mov     r2, rYreg
        mov     r3, rSP
        blx     print6502state
	pop	{r0,r1,r2} @ caller fixup (discard pushed params)
        pop     {r0-r3}
	.endm

@ print PC in hex
	.macro printpc
        push    {r0-r3}  @ could be clobbered
        mov     r0, rPC
        blx     printhex16
        pop     {r0-r3}
	.endm

@ print reg in two hex digits
	.macro printreghex8 reg
        push    {r0-r3}  @ could be clobbered
        mov     r0, \reg
        blx     printhex8
        pop     {r0-r3}
	.endm

@ print ascii character
	.macro printchar c
        push    {r0-r3}  @ could be clobbered
        mov     r0, #\c
        blx     printchar
        pop     {r0-r3}
	.endm

@ print newline and carriage return
	.macro printnlcr
	printchar '\n'
	printchar '\r'
	.endm

.macro load_operand_byte reg /* and increment PC */
	ldrb    \reg, [rPC, rmem]
	add	rPC, #1			@ ignore case of wrapping at 0xffff
.endm

.macro	load_2_operand_bytes reg /* and adjust PC */
	@ there may be a penalty for unaligned accesses but it's faster than doing it by hand
        ldrh	\reg, [rPC, rmem]	@ ignore case of wrapping at 0xffff
	add     rPC, #2			@ ignore case of wrapping at 0xffff
.endm

.macro setflags_pre
	MSR APSR, rPbyteHi
.endm

.macro setflags_post
	@ this action zeros the three lower bytes, which is why a single rPbyte cannot hold D and I
	MRS rPbyteHi, APSR
.endm

@ report bad instruction (dead end)
badinstruction:
	sub	rPC, #1
	ldrb	r0, [rPC, rmem]
	mov     r1, rPC
	blx	printbadinstruction
badinstruction_halt:
	b	badinstruction_halt

@ print machine state (subroutine)
.thumb_func
printstate:
	push    {lr}
	sub	rPC, #1		@ revert the PC to point to the opcode we just fetched
	printnlcr
	printreghex8 r0
	printreghex8 rPC
	add	rPC, #1
	pop	{lr}
	bx	lr

@ these compute_ea_MODE macros will also adjust the PC, return value in given reg
@ generally we expect to return ea in r1
@ if it turns out that we can always use r1 we can make it global and remove these parameters
@ when we have the ea, we'll get the operand into r0
@ in the meantime r0 is free to use

.macro compute_ea_zer eareg
        load_operand_byte \eareg
.endm

.macro compute_ea_abs eareg
	load_2_operand_bytes \eareg
.endm

.macro compute_ea_abx eareg
	compute_ea_abs_index \eareg rXreg
.endm

.macro compute_ea_aby eareg
	compute_ea_abs_index \eareg rYreg
.endm

.macro compute_ea_abs_index eareg rIndex
	load_2_operand_bytes \eareg
        and     r0, \rIndex, #0xff  @ index register is unsigned here
        add     \eareg, \eareg, r0
.endm

.macro compute_ea_zpx eareg  /* direct, X */
	compute_ea_zpreg \eareg rXreg
.endm

.macro compute_ea_zpy eareg  /* direct, Y */
	compute_ea_zpreg \eareg rYreg
.endm

.macro compute_ea_zpreg eareg index  /* direct, index */
        load_operand_byte \eareg
        add     \eareg, \index
        and     \eareg, #0xff
.endm

.macro compute_ea_inx eareg  /* (direct, X) - pre-indexed */
        load_operand_byte \eareg
        add     \eareg, rXreg
        and     \eareg, #0xff
        ldrh    \eareg, [\eareg, rmem] @ load both bytes - ignore 0xffff wraparound
.endm

.macro compute_ea_iny eareg  /* (direct), Y - post-indexed */
        load_operand_byte \eareg
        ldrh    \eareg, [\eareg, rmem] @ load both bytes - ignore 0xffff wraparound
        and     r0, rYreg, #0xff
	add	\eareg, \eareg, r0
.endm

@ dispatch next instruction
@    one plan is to append the dispatch to every instruction decode
@    but TBH instruction only goes forward and benefits from branch prediction
@    note that TBH is only available to CPUs with thumb2
@    note also that thumb2 is the only instruction set available on the disco board (Cortex-M3)

.macro dispatch
        ldrb	r0, [rmem, rPC]

/* it would be neat to enable tracing if the user pushbutton is pressed */
/* also to have other triggering conditions, such as instruction count, PC value, memory access */
/* we'll put up with an emulator (wdm) operation */
#ifdef TRACE6502
	cmp	rTrace, #0
	beq	nottracing
	print6502state
nottracing:
#endif

	add	rPC, #1    @ no auto increment in thumb
	tbh	[pc, r0, lsl #1] @ branch table only goes forward so pc-based is no loss
.endm

.macro op opcode mnemonic addressmode
	@ r0 holds the opcode, rPC is already incremented
	l_\opcode:
	do_\mnemonic \addressmode
	postamble \opcode
.endm

.macro postamble opcode
@	bl	printstate
	b	loophead
.endm

.thumb_func
.globl emulator
emulator:
	@ we're not returning to main() so we don't save any registers
	mov	rPC, r0
	mov	rmem, r1
	mov	rTrace, #0
	mov	rMask24, #0xffffff
	mov	rPbyteLo, #(pByteXflag|pByteBflag)	@ set fixed bits 4 and 5 of 6502 status reg

	@ we must at least mask the (uninitialised) register values
	@ (PC was initialised by the caller)
	and	rAcc, rAcc, #0xff
	and	rXreg, rXreg, #0xff
	and	rYreg, rYreg, #0xff
	mov	rSP, #0xff	@ actually initialise SP (because we don't presently handle wrapping quite correctly)

        printnlcr
        printchar 'G'
        printchar 'o'
        printchar ':'
        printchar ' '
	printpc   @ just for confidence that we arrived
        printnlcr

loophead:
	dispatch  @ launch the first instruction (at least)

dt: @ dispatch table
        .hword ((l_00-dt)/2), ((l_01-dt)/2), ((l_02-dt)/2), ((l_03-dt)/2), ((l_04-dt)/2), ((l_05-dt)/2), ((l_06-dt)/2), ((l_07-dt)/2)
        .hword ((l_08-dt)/2), ((l_09-dt)/2), ((l_0a-dt)/2), ((l_0b-dt)/2), ((l_0c-dt)/2), ((l_0d-dt)/2), ((l_0e-dt)/2), ((l_0f-dt)/2)
        .hword ((l_10-dt)/2), ((l_11-dt)/2), ((l_12-dt)/2), ((l_13-dt)/2), ((l_14-dt)/2), ((l_15-dt)/2), ((l_16-dt)/2), ((l_17-dt)/2)
        .hword ((l_18-dt)/2), ((l_19-dt)/2), ((l_1a-dt)/2), ((l_1b-dt)/2), ((l_1c-dt)/2), ((l_1d-dt)/2), ((l_1e-dt)/2), ((l_1f-dt)/2)

        .hword ((l_20-dt)/2), ((l_21-dt)/2), ((l_22-dt)/2), ((l_23-dt)/2), ((l_24-dt)/2), ((l_25-dt)/2), ((l_26-dt)/2), ((l_27-dt)/2)
        .hword ((l_28-dt)/2), ((l_29-dt)/2), ((l_2a-dt)/2), ((l_2b-dt)/2), ((l_2c-dt)/2), ((l_2d-dt)/2), ((l_2e-dt)/2), ((l_2f-dt)/2)
        .hword ((l_30-dt)/2), ((l_31-dt)/2), ((l_32-dt)/2), ((l_33-dt)/2), ((l_34-dt)/2), ((l_35-dt)/2), ((l_36-dt)/2), ((l_37-dt)/2)
        .hword ((l_38-dt)/2), ((l_39-dt)/2), ((l_3a-dt)/2), ((l_3b-dt)/2), ((l_3c-dt)/2), ((l_3d-dt)/2), ((l_3e-dt)/2), ((l_3f-dt)/2)

        .hword ((l_40-dt)/2), ((l_41-dt)/2), ((l_42-dt)/2), ((l_43-dt)/2), ((l_44-dt)/2), ((l_45-dt)/2), ((l_46-dt)/2), ((l_47-dt)/2)
        .hword ((l_48-dt)/2), ((l_49-dt)/2), ((l_4a-dt)/2), ((l_4b-dt)/2), ((l_4c-dt)/2), ((l_4d-dt)/2), ((l_4e-dt)/2), ((l_4f-dt)/2)
        .hword ((l_50-dt)/2), ((l_51-dt)/2), ((l_52-dt)/2), ((l_53-dt)/2), ((l_54-dt)/2), ((l_55-dt)/2), ((l_56-dt)/2), ((l_57-dt)/2)
        .hword ((l_58-dt)/2), ((l_59-dt)/2), ((l_5a-dt)/2), ((l_5b-dt)/2), ((l_5c-dt)/2), ((l_5d-dt)/2), ((l_5e-dt)/2), ((l_5f-dt)/2)

        .hword ((l_60-dt)/2), ((l_61-dt)/2), ((l_62-dt)/2), ((l_63-dt)/2), ((l_64-dt)/2), ((l_65-dt)/2), ((l_66-dt)/2), ((l_67-dt)/2)
        .hword ((l_68-dt)/2), ((l_69-dt)/2), ((l_6a-dt)/2), ((l_6b-dt)/2), ((l_6c-dt)/2), ((l_6d-dt)/2), ((l_6e-dt)/2), ((l_6f-dt)/2)
        .hword ((l_70-dt)/2), ((l_71-dt)/2), ((l_72-dt)/2), ((l_73-dt)/2), ((l_74-dt)/2), ((l_75-dt)/2), ((l_76-dt)/2), ((l_77-dt)/2)
        .hword ((l_78-dt)/2), ((l_79-dt)/2), ((l_7a-dt)/2), ((l_7b-dt)/2), ((l_7c-dt)/2), ((l_7d-dt)/2), ((l_7e-dt)/2), ((l_7f-dt)/2)

        .hword ((l_80-dt)/2), ((l_81-dt)/2), ((l_82-dt)/2), ((l_83-dt)/2), ((l_84-dt)/2), ((l_85-dt)/2), ((l_86-dt)/2), ((l_87-dt)/2)
        .hword ((l_88-dt)/2), ((l_89-dt)/2), ((l_8a-dt)/2), ((l_8b-dt)/2), ((l_8c-dt)/2), ((l_8d-dt)/2), ((l_8e-dt)/2), ((l_8f-dt)/2)
        .hword ((l_90-dt)/2), ((l_91-dt)/2), ((l_92-dt)/2), ((l_93-dt)/2), ((l_94-dt)/2), ((l_95-dt)/2), ((l_96-dt)/2), ((l_97-dt)/2)
        .hword ((l_98-dt)/2), ((l_99-dt)/2), ((l_9a-dt)/2), ((l_9b-dt)/2), ((l_9c-dt)/2), ((l_9d-dt)/2), ((l_9e-dt)/2), ((l_9f-dt)/2)

        .hword ((l_a0-dt)/2), ((l_a1-dt)/2), ((l_a2-dt)/2), ((l_a3-dt)/2), ((l_a4-dt)/2), ((l_a5-dt)/2), ((l_a6-dt)/2), ((l_a7-dt)/2)
        .hword ((l_a8-dt)/2), ((l_a9-dt)/2), ((l_aa-dt)/2), ((l_ab-dt)/2), ((l_ac-dt)/2), ((l_ad-dt)/2), ((l_ae-dt)/2), ((l_af-dt)/2)
        .hword ((l_b0-dt)/2), ((l_b1-dt)/2), ((l_b2-dt)/2), ((l_b3-dt)/2), ((l_b4-dt)/2), ((l_b5-dt)/2), ((l_b6-dt)/2), ((l_b7-dt)/2)
        .hword ((l_b8-dt)/2), ((l_b9-dt)/2), ((l_ba-dt)/2), ((l_bb-dt)/2), ((l_bc-dt)/2), ((l_bd-dt)/2), ((l_be-dt)/2), ((l_bf-dt)/2)

        .hword ((l_c0-dt)/2), ((l_c1-dt)/2), ((l_c2-dt)/2), ((l_c3-dt)/2), ((l_c4-dt)/2), ((l_c5-dt)/2), ((l_c6-dt)/2), ((l_c7-dt)/2)
        .hword ((l_c8-dt)/2), ((l_c9-dt)/2), ((l_ca-dt)/2), ((l_cb-dt)/2), ((l_cc-dt)/2), ((l_cd-dt)/2), ((l_ce-dt)/2), ((l_cf-dt)/2)
        .hword ((l_d0-dt)/2), ((l_d1-dt)/2), ((l_d2-dt)/2), ((l_d3-dt)/2), ((l_d4-dt)/2), ((l_d5-dt)/2), ((l_d6-dt)/2), ((l_d7-dt)/2)
        .hword ((l_d8-dt)/2), ((l_d9-dt)/2), ((l_da-dt)/2), ((l_db-dt)/2), ((l_dc-dt)/2), ((l_dd-dt)/2), ((l_de-dt)/2), ((l_df-dt)/2)

        .hword ((l_e0-dt)/2), ((l_e1-dt)/2), ((l_e2-dt)/2), ((l_e3-dt)/2), ((l_e4-dt)/2), ((l_e5-dt)/2), ((l_e6-dt)/2), ((l_e7-dt)/2)
        .hword ((l_e8-dt)/2), ((l_e9-dt)/2), ((l_ea-dt)/2), ((l_eb-dt)/2), ((l_ec-dt)/2), ((l_ed-dt)/2), ((l_ee-dt)/2), ((l_ef-dt)/2)
        .hword ((l_f0-dt)/2), ((l_f1-dt)/2), ((l_f2-dt)/2), ((l_f3-dt)/2), ((l_f4-dt)/2), ((l_f5-dt)/2), ((l_f6-dt)/2), ((l_f7-dt)/2)
        .hword ((l_f8-dt)/2), ((l_f9-dt)/2), ((l_fa-dt)/2), ((l_fb-dt)/2), ((l_fc-dt)/2), ((l_fd-dt)/2), ((l_fe-dt)/2), ((l_ff-dt)/2)


@ overall for each instruction dispatched we will need to:
@    compute effective address (if any) and adjust PC
@      note that the effective address for an immediate is PC
@    fetch operand (if any)
@    perform operation
@    store to memory (if necessary)
@    proceed to next instruction

/* trivial cases */

.macro do_bad addressmode
	b badinstruction
.endm

.macro do_nop addressmode
.endm

/* emulation special functions such as i/o - call out to C code */
.macro do_wdm addressmode
	load_operand_byte r0	@ WDM operand is operation code
	mov	r1, rAcc	@ Accumulator is parameter byte

	@ deal with tracing control
	cmp	r0, #0x54
	bne	wdm_c
	mov	rTrace, #1
wdm_c:
        push    {r1-r3}  @ could be clobbered
	blx	wdm_handler
        pop     {r1-r3}
	mov	rAcc, r0	@ Accumulator is result byte FIXME no status reg update - may be applicable only in some cases
.endm

/* register transfers */

.macro do_t src dst	@ we also use this as a general primitive to load a reg with N and Z flag updates
	@ note that shifts can perturb the C bit (also cmp #0)
	@ (it might be quicker to test directly to set N and Z)
	@ (or indeed to hold values <<24 for most of the time)
	mov	\dst, \src, lsl #24  @ shift to get N flag and to mask to a byte
	setflags_pre
	teq	\dst, #0
	setflags_post
	mov	\dst, \dst, lsr #24  @ consider asr, then we get sign extension for future use
.endm

.macro do_tax addressmode
	do_t rAcc rXreg
.endm

.macro do_tay addressmode
	do_t rAcc rYreg
.endm

.macro do_txa addressmode
	do_t rXreg rAcc
.endm

.macro do_tya addressmode
	do_t rYreg rAcc
.endm

.macro do_tsx addressmode
	do_t rSP rXreg
.endm

.macro do_txs addressmode
	mov	rSP, rXreg  @ perform directly because txs doesn't affect the flags
.endm

/* store */
.macro do_streg reg addressmode
	compute_ea_\addressmode r1
	strb \reg, [r1, rmem]
.endm

.macro do_sta addressmode
	do_streg rAcc \addressmode
.endm

.macro do_stx addressmode
	do_streg rXreg \addressmode
.endm

.macro do_sty addressmode
	do_streg rYreg \addressmode
.endm

/* load */

.macro load_operand_and_ea addressmode Rop Rea
	.ifc \addressmode,imm
	load_operand_byte \Rop
	.else
	compute_ea_\addressmode \Rea
	ldrb    \Rop, [\Rea, rmem]
	.endif
.endm

.macro do_loadreg reg addressmode
	load_operand_and_ea \addressmode r0 r1
	do_t r0, \reg
.endm

.macro do_lda addressmode
	do_loadreg rAcc \addressmode
.endm

.macro do_ldx addressmode
	do_loadreg rXreg \addressmode
.endm

.macro do_ldy addressmode
	do_loadreg rYreg \addressmode
.endm

/* processor flags */
.macro do_sec addressmode
	orr	rPbyteHi, #armCflag
.endm

.macro do_sed addressmode
	orr	rPbyteLo, #pByteDflag
.endm

.macro do_sei addressmode
	orr	rPbyteLo, #pByteIflag
.endm

.macro do_clc addressmode
	bic	rPbyteHi, #armCflag
.endm

.macro do_cld addressmode
	bic	rPbyteLo, #pByteDflag
.endm

.macro do_cli addressmode
	bic	rPbyteLo, #pByteIflag
.endm

.macro do_clv addressmode
	bic	rPbyteHi, #armVflag
.endm

/* branches */

.macro do_branch why
	ldrsb	r0, [rPC, rmem] 	@ load a signed operand
	add	rPC, #1			@ ignore case of wrapping at 0xffff
	setflags_pre
	it \why
	add\why	rPC, r0			@ ignore case of wrapping at 0xffff
.endm

.macro do_bcc addressmode
	do_branch cc
.endm

.macro do_bcs addressmode
	do_branch cs
.endm

.macro do_beq addressmode
	do_branch eq
.endm

.macro do_bmi addressmode
	do_branch mi
.endm

.macro do_bne addressmode
	do_branch ne
.endm

.macro do_bpl addressmode
	do_branch pl
.endm

.macro do_bvc addressmode
	do_branch vc
.endm

.macro do_bvs addressmode
	do_branch vs
.endm

/* jumps and returns */

.macro do_jmp addressmode
	@ for efficiency in this case we don't use the macro load_2_operand_bytes
	ldrh	rPC, [rPC, rmem]	@ ignore case of wrapping
	.ifc \addressmode,ind
	ldrh	rPC, [rPC, rmem]	@ ignore case of wrapping
	.endif
.endm

.macro do_jsr addressmode
	load_operand_byte r0
	@ we have half our operand, and PC now ready for stack push
	add	r1, rSP, #0xff  @ 6502 stack is at 0x100
	strh	rPC, [r1, rmem] @ ignore case of stack pointer wrapping between the 2 pushes
	sub	rSP, #2
	and	rSP, #0xff  @ consider possibility of having bit 8 of rSP set to 1 always??

	mov	r1, r0    @ low byte of destination
	load_operand_byte r0
	add	rPC, r1, r0, lsl #8
.endm

.macro do_brk addressmode
	add     rPC, #1		@ ignore possibility of wrap

	@ push PC - this code very like the jsr
	add	r1, rSP, #0xff  @ 6502 stack is at 0x100
	strh	rPC, [r1, rmem] @ ignore case of stack pointer wrapping between the 2 pushes
	sub	rSP, #2
	and	rSP, #0xff  @ consider possibility of having bit 8 of rSP set to 1 always??

	@ push pByte in 6502 format
	do_php imp
	orr	rPbyteLo, #pByteIflag  @ BRK sets interrupt disable just as IRQ would

	mov	r0, #0x10000
	sub	r0, #2		@ brk/irq vector is 0xfffe
	ldrh	rPC, [r0, rmem]
.endm

.macro do_rts addressmode
	add     r1, rSP, #0x101  @ 6502 stack is at 0x100
	ldrh	rPC, [r1, rmem]  @ ignore case of stack pointer wrapping between the 2 pulls
	add	rSP, #2
	and	rSP, #0xff	 @ deal with stack wrapping for once
	add	rPC, #1		 @ ignore possibility of wrap
.endm

.macro do_rti addressmode
	do_plp

	add     r1, rSP, #0x101  @ 6502 stack is at 0x100
	ldrh	rPC, [r1, rmem]  @ ignore case of stack pointer wrapping between the 2 pulls
	add	rSP, #2		 @ ignore possibility of wrap
	and	rSP, #0xff		@ deal with stack wrapping for once
.endm

/* more stack operations */

.macro do_pha addressmode
	pushbyte rAcc
.endm

.macro pushbyte reg
	add     r1, rSP, #0x100
	strb	\reg, [r1, rmem]
	sub     rSP, #1
	and     rSP, #0xff
.endm

.macro pullbyte reg
	add	rSP, #1 
	and	rSP, #0xff
	add     r1, rSP, #0x100
	ldrb	\reg, [r1, rmem]
.endm

.macro do_pla addressmode
	pullbyte rAcc
	do_t rAcc, rAcc
.endm

.macro do_php addressmode
	pByteToR0
	pushbyte r0
.endm

.macro do_plp addressmode
	pullbyte r0
	r0toPByte
.endm

/* at least one class of read modify write - inc and dec */

.macro do_rmw op addressmode
	compute_ea_\addressmode	r1 @ calculate effective address and update PC
	ldrb	r0, [r1, rmem]
	\op	r0		@ operate, mask, update status flags
	strb	r0, [r1, rmem]
.endm

.macro rmw_dec reg
	do_rmwincdec dec \reg
.endm

.macro rmw_inc reg
	do_rmwincdec inc \reg
.endm

.macro do_dec addressmode
	do_rmw rmw_dec \addressmode
.endm

.macro do_inc addressmode
	do_rmw rmw_inc \addressmode
.endm

.macro do_rmwincdec action reg
	@ FIXME this is not efficient: operating and then later transferring to set the flags
	.ifc \action, inc
	add	r0, \reg, #1
	.else
	sub	r0, \reg, #1
	.endif
	do_t r0, \reg
.endm

.macro do_inx addressmode
	do_rmwincdec inc rXreg
.endm

.macro do_iny addressmode
	do_rmwincdec inc rYreg
.endm

.macro do_dex addressmode
	do_rmwincdec dec rXreg
.endm

.macro do_dey addressmode
	do_rmwincdec dec rYreg
.endm

/* arithmetic and logical,  2-operand, not RMW */

.macro do_addsub addressmode op c @ not handling decimal mode!
	load_operand_and_ea \addressmode r0 r1	@ in this case we don't need the effective address
	mov	r0, r0, asl #24
	mov	rAcc, rAcc, asl #24	@ can't manage to combine shift with subtract - lacking reverse subtract with carry
	setflags_pre
	it \c
	orr\c	r0, r0, rMask24		@ allow carry in to count
	\op	r0, rAcc, r0		@ the overflow flag can only work if we shift everything by 24
	setflags_post
	mov	rAcc, r0, lsr #24	@ this might all be cheaper if the acc was top-aligned (indexed addressing might be more expensive?)
.endm

.macro do_adc addressmode  @ not handling decimal mode!
	do_addsub \addressmode adcs cs
.endm

.macro do_sbc addressmode  @ not handling decimal mode!
	do_addsub \addressmode sbcs cc
.endm

.macro do_compare addressmode reg
	@ somewhat like addsub, but ARM CMP sets V flag whereas 6502 CMP does not
	load_operand_and_ea \addressmode r0 r1	@ in this case we don't need the effective address
	mov	r0, r0, asl #24   @ we left-justify to get N correct
	mov	r1, \reg, asl #24
	setflags_pre
	cmp	r1, r0		@ this has set N and Z, not V (or C)
	MRS	r0, APSR	@ these manipulations feel pedestrian - could probably do better
	bic	r0, #armVflag
	tst	rPbyteHi, #armVflag
	it ne
	orrne	r0, #armVflag
	mov	rPbyteHi, r0
.endm

.macro do_cmp addressmode
	do_compare \addressmode rAcc
.endm

.macro do_cpx addressmode
	do_compare \addressmode rXreg
.endm

.macro do_cpy addressmode
	do_compare \addressmode rYreg
.endm

.macro do_logic addressmode op 
	@ even for logic ops we need to shift to get N flag correct
	load_operand_and_ea \addressmode r0 r1	@ in this case we don't need the effective address
	\op	r0, rAcc, r0
	do_t r0 rAcc
.endm

.macro do_and addressmode
	do_logic \addressmode and
.endm

.macro do_eor addressmode
	do_logic \addressmode eor
.endm

.macro do_ora addressmode
	do_logic \addressmode orr
.endm

.macro do_bit addressmode
	@ we don't need to shift for logic ops
	load_operand_and_ea \addressmode r0 r1	@ in this case we don't need the effective address

	@ N bit and V bit to be set from bits 7 and 6 of the operand
	@ r0:      -------- xx xx NV------
	@ r1:	   -Z------ xx xx --------
	@ rPbyte:  NZCV---- xx xx --11DI--  (Now split into rPbyteHi and rPbyteLo)

	bic	rPbyteHi, #(armNflag | armZflag | armVflag)

	tst	rAcc, r0		@ determine Z flag from AND
	it eq
	orreq	rPbyteHi, #armZflag

	tst	r0, #0x80
	it ne
	orrne	rPbyteHi, #armNflag

	tst	r0, #0x40
	it ne
	orrne	rPbyteHi, #armVflag
.endm


/* shift and rotate - read modify write, or accumulator */

.macro do_asl addressmode
	.ifc \addressmode,acc
	setflags_pre
	movs	rAcc, rAcc, lsl #25
	setflags_post
	mov	rAcc, rAcc, lsr #24
	.else
	load_operand_and_ea \addressmode r0 r1
	setflags_pre
	movs	r0, r0, lsl #25
	setflags_post
	mov	r0, r0, lsr #24
	strb r0, [r1, rmem]
	.endif
.endm

.macro do_lsr addressmode
	.ifc \addressmode,acc
	setflags_pre
	movs	rAcc, rAcc, lsr #1
	setflags_post
	.else
	load_operand_and_ea \addressmode r0 r1
	setflags_pre
	movs	r0, r0, lsr #1
	setflags_post
	strb r0, [r1, rmem]
	.endif
.endm

.macro do_rol_inner reg
	setflags_pre
	adc	\reg, \reg	@ bring in carry, make 9-bit value
	lsls	\reg, #24	@ left-justify, set flags
	setflags_post
	lsr	\reg, #24
.endm

.macro do_ror_inner reg
	@ arm: C -- -- -- XX C
	@ arm: C XX -- -- -- C
	@ arm: C XX -- -- XX C
	@ arm: C -- -- -- XX C

	setflags_pre
	it cs
	orrcs   \reg, #0x100	@ fixup the incoming carry
	tst	\reg, #0x1	@ detect the outgoing carry
	it ne
	orrne	\reg, #0x200	@ propagate the outgoing carry
	bic     \reg, #0x1      @ clear bit 1
	lsls	\reg, #23	@ left-justify to set N and Z
	setflags_post
	lsr	\reg, #24
.endm

.macro do_rol addressmode
	@ arm ROL doesn't involve the C bit
	@ arm:  -- -- -- XX C
	.ifc \addressmode,acc
	do_rol_inner rAcc
	.else
	load_operand_and_ea \addressmode r0 r1
	do_rol_inner r0
	strb r0, [r1, rmem]
	.endif
.endm

.macro do_ror addressmode
	.ifc \addressmode,acc
	do_ror_inner rAcc
	.else
	load_operand_and_ea \addressmode r0 r1
	do_ror_inner r0
	strb r0, [r1, rmem]
	.endif
.endm

     /* 6502 instruction set */
     op 00 brk imp
     op 01 ora inx
     op 02 bad non
     op 03 bad non
     op 04 bad non /* tsb zer @ 65c02 */
     op 05 ora zer
     op 06 asl zer
     op 07 bad non
   
     op 08 php imp
     op 09 ora imm
     op 0a asl acc
     op 0b bad non
     op 0c bad non /* tsb abs @ 65c02 */
     op 0d ora abs
     op 0e asl abs
     op 0f bad non
   
     op 10 bpl rel
     op 11 ora iny
     op 12 bad non /* ora drp @ 65c02 */
     op 13 bad non
     op 14 bad non /* trb zer @ 65c02 */
     op 15 ora zpx
     op 16 asl zpx
     op 17 bad non
   
     op 18 clc imp
     op 19 ora aby
     op 1a bad non /* inc imp @ 65c02 */
     op 1b bad non
     op 1c bad non /* trb abs @ 65c02 */
     op 1d ora abx
     op 1e asl abx
     op 1f bad non
   
     op 20 jsr abs
     op 21 and inx
     op 22 bad non
     op 23 bad non
     op 24 bit zer
     op 25 and zer
     op 26 rol zer
     op 27 bad non
   
     op 28 plp imp
     op 29 and imm
     op 2a rol acc
     op 2b bad non
     op 2c bit abs
     op 2d and abs
     op 2e rol abs
     op 2f bad non
   
     op 30 bmi rel
     op 31 and iny
     op 32 bad non /* and drp @ 65c02 */
     op 33 bad non
     op 34 bad non /* bit zpx @ 65c02 */
     op 35 and zpx
     op 36 rol zpx
     op 37 bad non
   
     op 38 sec imp
     op 39 and aby
     op 3a bad non /* dec imp @ 65c02 */
     op 3b bad non
     op 3c bad non /* bit abx @ 65c02 */
     op 3d and abx
     op 3e rol abx
     op 3f bad non
   
     op 40 rti imp
     op 41 eor inx
     op 42 wdm imm /* 65816 and emulation extension */
     op 43 bad non
     op 44 bad non
     op 45 eor zer
     op 46 lsr zer
     op 47 bad non
   
     op 48 pha imp
     op 49 eor imm
     op 4a lsr acc
     op 4b bad non
     op 4c jmp abs
     op 4d eor abs
     op 4e lsr abs
     op 4f bad non
   
     op 50 bvc rel
     op 51 eor iny
     op 52 bad non /* eor drp @ 65c02 */
     op 53 bad non
     op 54 bad non
     op 55 eor zpx
     op 56 lsr zpx
     op 57 bad non
   
     op 58 cli imp
     op 59 eor aby
     op 5a bad non /* phy imp @ 65c02 */
     op 5b bad non
     op 5c bad non
     op 5d eor abx
     op 5e lsr abx
     op 5f bad non
   
     op 60 rts imp
     op 61 adc inx
     op 62 bad non
     op 63 bad non
     op 64 bad non /* stz zer @ 65c02 */
     op 65 adc zer
     op 66 ror zer
     op 67 bad non
   
     op 68 pla imp
     op 69 adc imm
     op 6a ror acc
     op 6b bad non
     op 6c jmp ind
     op 6d adc abs
     op 6e ror abs
     op 6f bad non
   
     op 70 bvs rel
     op 71 adc iny
     op 72 bad non /* adc drp @ 65c02 */
     op 73 bad non
     op 74 bad non /* stz zpx @ 65c02 */
     op 75 adc zpx
     op 76 ror zpx
     op 77 bad non
   
     op 78 sei imp
     op 79 adc aby
     op 7a bad non /* ply imp @ 65c02 */
     op 7b bad non
     op 7c bad non /* jmp inx @ 65c02 */
     op 7d adc abx
     op 7e ror abx
     op 7f bad non
   
     op 80 bad non /* bra rel @ 65c02 */
     op 81 sta inx
     op 82 bad non
     op 83 bad non
     op 84 sty zer
     op 85 sta zer
     op 86 stx zer
     op 87 bad non
   
     op 88 dey imp
     op 89 bad non /* bit imm @ 65c02 */
     op 8a txa imp
     op 8b bad non
     op 8c sty abs
     op 8d sta abs
     op 8e stx abs
     op 8f bad non
   
     op 90 bcc rel
     op 91 sta iny
     op 92 bad non /* sta drp @ 65c02 */
     op 93 bad non
     op 94 sty zpx
     op 95 sta zpx
     op 96 stx zpy
     op 97 bad non
   
     op 98 tya imp
     op 99 sta aby
     op 9a txs imp
     op 9b bad non
     op 9c bad non /* stz abs @ 65c02 */
     op 9d sta abx
     op 9e bad non /* stz abx @ 65c02 */
     op 9f bad non
   
     op a0 ldy imm
     op a1 lda inx
     op a2 ldx imm
     op a3 bad non
     op a4 ldy zer
     op a5 lda zer
     op a6 ldx zer
     op a7 bad non
   
     op a8 tay imp
     op a9 lda imm
     op aa tax imp
     op ab bad non
     op ac ldy abs
     op ad lda abs
     op ae ldx abs
     op af bad non
   
     op b0 bcs rel
     op b1 lda iny
     op b2 bad non /* lda drp @ 65c02 */
     op b3 bad non
     op b4 ldy zpx
     op b5 lda zpx
     op b6 ldx zpy
     op b7 bad non
   
     op b8 clv imp
     op b9 lda aby
     op ba tsx imp
     op bb bad non
     op bc ldy abx
     op bd lda abx
     op be ldx aby
     op bf bad non
   
     op c0 cpy imm
     op c1 cmp inx
     op c2 bad non
     op c3 bad non
     op c4 cpy zer
     op c5 cmp zer
     op c6 dec zer
     op c7 bad non
   
     op c8 iny imp
     op c9 cmp imm
     op ca dex imp
     op cb bad non
     op cc cpy abs
     op cd cmp abs
     op ce dec abs
     op cf bad non
   
     op d0 bne rel
     op d1 cmp iny
     op d2 bad non /* cmp drp @ 65c02 */
     op d3 bad non
     op d4 bad non
     op d5 cmp zpx
     op d6 dec zpx
     op d7 bad non
   
     op d8 cld imp
     op d9 cmp aby
     op da bad non /* phx imp @ 65c02 */
     op db bad non
     op dc bad non
     op dd cmp abx
     op de dec abx
     op df bad non
   
     op e0 cpx imm
     op e1 sbc inx
     op e2 bad non
     op e3 bad non
     op e4 cpx zer
     op e5 sbc zer
     op e6 inc zer
     op e7 bad non
   
     op e8 inx imp
     op e9 sbc imm
     op ea nop imp
     op eb bad non
     op ec cpx abs
     op ed sbc abs
     op ee inc abs
     op ef bad non
   
     op f0 beq rel
     op f1 sbc iny
     op f2 bad non /* sbc drp @ 65c02 */
     op f3 bad non
     op f4 bad non
     op f5 sbc zpx
     op f6 inc zpx
     op f7 bad non
   
     op f8 sed imp
     op f9 sbc aby
     op fa bad non /* plx imp @ 65c02 */
     op fb bad non
     op fc bad non
     op fd sbc abx
     op fe inc abx
     op ff bad non
   
@ EOF
