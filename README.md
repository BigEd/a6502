The a6502 project is a 6502 emulator (library) written in ARM assembly.

(Strictly, it's in Thumb-2 assembly, because it's intended for a
particular dev board, the STM32F4DISCOVERY, which has a Cortex-M4
and that core will only run in Thumb mode.)

On that dev board, the CPU runs at 168MHz and the emulated speed of
the 6502 is 18MHz.

The project is inspired by Chris Baird's stm6502, and likewise offers
a 6502 with 64k RAM and a serial connection.  In this case the serial
connection is over USB, and I/O is performed by an extended opcode
instead of being memory-mapped.

The code takes some ideas from Acorn's 65Tube and from Ian Piumarta's
lib6502, but both of those have incompatible copyright so this isn't a
direct descendant of either.

Broadly, the LGPL license allows use in pretty much any project
(whether open or closed source, free or commercial,) provided any
binary distribution is accompanied by source.

Refer to the stm6502 project for details about tools and downloading
built firmware.  The Makefile here will build a *.bin which includes
a memory image populated with 6502 software from that project:
  - supermon64 at F800, entered at reset
  - figforth at 0200 (g 0200)
  - EhBASIC at c800 (g c800)

The memory image is called
  basfigmon.img
and was built with 'dd' commands from binaries found in stm6502 -
sources are found in that project. 

A microUSB cable connected to the south edge of the dev board offers
a serial connection to the emulated CPU, which communicates using
  42 00   for output - writes the char in A
  42 01 for input (will block) - reads the char in A

It's not possible for the 6502 to read a null byte, as zero is used as
a sentinel value.  The provided C routine which handles opcode 42
(wdm) translates between \n and \r characters. 

At present the emulator does not emulate decimal mode, or model the
four non-essential bits of the status register. Only NVZC are
modelled. It's not too hard to fix both of these.

The three ROMs mentioned above seem to work correctly, as do some
trivial test sequences found in top.c - bug reports are welcome.

(EhBASIC needs decimal mode only for HEX$() which is therefore
presently mibehaving.)OC

Remodelling the emulator in Thumb or ARM assembly might be interesting
- ARM would be easier.
