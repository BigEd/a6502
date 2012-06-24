##
## This file is part of the a6502 project.
##
## Copyright (C) 2012 Ed Spittles <ed.spittles@gmail.com>
##
## This library is free software: you can redistribute it and/or modify
## it under the terms of the GNU Lesser General Public License as published by
## the Free Software Foundation, either version 3 of the License, or
## (at your option) any later version.
##
## This library is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU Lesser General Public License for more details.
##
## You should have received a copy of the GNU Lesser General Public License
## along with this library.  If not, see <http://www.gnu.org/licenses/>.
##

CC=arm-none-eabi-gcc
CCOPTS=-mcpu=cortex-m4 -std=c99 -Os -g -Wall -Wextra \
       -fno-common -mcpu=cortex-m4 -mthumb -msoft-float -MD -DSTM32F4

LD=arm-none-eabi-gcc
LDOPTS=-lopencm3_stm32f4 -lc -lnosys \
       -T./stm32f4-discovery.ld -nostartfiles -Wl,--gc-sections \
       -mthumb -mcpu=cortex-m4 -march=armv7 -mfix-cortex-m3-ldrd -msoft-float

OBJCP=arm-none-eabi-objcopy

all : a6502.bin

clean :
	rm -f *.o *.bin *.elf *.d

a6502.o : a6502.c
	$(CC) $(CCOPTS) -c $<

emulator.o : emulator.S
	$(CC) $(CCOPTS) -c $<

memimage.o : memimage.s basfigmon.img
	$(CC) $(CCOPTS) -c $<

top.o : top.c
	$(CC) $(CCOPTS) -c $<

a6502.elf : a6502.o top.o emulator.o memimage.o
	$(LD) -o $@ $^ $(LDOPTS)

%.bin : %.elf
	$(OBJCP) -Obinary $^ $@
	echo now write to dev board with: st-flash write a6502.bin 0x08000000

# arm-none-eabi-objcopy -Oihex a6502.elf a6502.hex
# arm-none-eabi-objcopy -Osrec a6502.elf a6502.srec
# arm-none-eabi-objdump -S a6502.elf > a6502.list
