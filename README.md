The a6502 project is a 6502 emulator (library) written in ARM assembly.

(Strictly, it's in Thumb-2 assembly, because it's intended for a
particular dev board, the STM32F4DISCOVERY, which has a Cortex-M4
and that core will only run in Thumb mode.)

On that dev board, the CPU runs at 168MHz and the emulated speed of
the 6502 is 18MHz.

The project is inspired by [Chris Baird's stm6502](https://github.com/BigEd/stm6502), and likewise offers
a 6502 with 64k RAM and a serial connection.  In this case the serial
connection is over USB, and I/O is performed by an extended opcode
instead of being memory-mapped.

The code takes some ideas from Acorn's [65Tube](http://www.chiark.greenend.org.uk/~theom/riscos/docs/RISCOS2/Emulate65.txt) and from Ian Piumarta's
[lib6502](http://www.piumarta.com/software/lib6502/), but both of those have incompatible copyright so this isn't a
direct descendant of either.

Broadly, the LGPL license allows use in pretty much any project
(whether open or closed source, free or commercial,) provided any
binary distribution is accompanied by source.

Refer to the stm6502 project for details about tools and downloading
built firmware.  The Makefile here will build a *.bin which includes
an initial memory image for the 6502 - usually that would include a
bootstrap ROM, monitor or application. 

For convenience, there's a built a6502.bin file included in a subdirectory.
It includes only the minimal C'mon monitor by Bruce Clark.
(This binary file is derived in part from other open source
projects and does not form part of the source of this project.)

An example memory image called `basfigmon.img` is provided for
convenience only, and does not form part of the source
of this project. It was built with 'dd' commands from binaries found
in stm6502 - sources are found in that project. It contains:
  - supermon64 at F800, entered at reset
  - figforth at 0200 (g 0200)
  - EhBASIC at c800 (g c800)
The file `basfigmon.bin` is a loadable a6502 built with this image.

A microUSB cable connected to the south edge of the dev board offers
a serial connection to the emulated CPU, which communicates using
  - 42 00 for output - writes the char in A
  - 42 01 for input (will block) - reads the char in A

It's not possible for the 6502 to read a null byte, as zero is used as
a sentinel value.  The provided C routine which handles opcode 42
(WDM) also translates between \n and \r characters. 

The three ROMs mentioned above seem to work correctly, as do some
trivial test sequences found in top.c - bug reports are welcome.

At present the emulator does not emulate decimal mode, but otherwise
it passes [Klaus Dormann's test suite](http://forum.6502.org/viewtopic.php?f=2&t=2241).

EhBASIC needs decimal mode only for HEX$() which is therefore
presently misbehaving.

Remodelling the emulator in Thumb or ARM assembly might be interesting
(ARM would be the easier case.)
