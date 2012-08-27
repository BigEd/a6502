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

#include <stdlib.h>
#include <stdio.h>
#include <libopencm3/usb/usbd.h>
#include <libopencm3/usb/cdc.h>

extern char MEMIMAGE[];
extern char MEMIMAGE_END[]; /* not an array but the end label to calculate length */

extern int emulator(int v, char *mem);
extern char usb_rx_buf[]; 
char usb_tx_buf[200];

void writechar(int c){
	usb_tx_buf[0]=c;
	while (usbd_ep_write_packet(0x82, usb_tx_buf, 1) == 0)
		;
}

void writestring64(char *s, int n){
	while (usbd_ep_write_packet(0x82, s, n) == 0)
		;
}

void printchar(int c){
	writechar(c);
}

void printhex8(int h){
	int n=sprintf(usb_tx_buf, " %02x ", h);
	for(int i=0;i<n;i++)
		writechar(usb_tx_buf[i]);
}

void printhex16(int h){
	int n=sprintf(usb_tx_buf, " %04x ", h);
	for(int i=0;i<n;i++)
		writechar(usb_tx_buf[i]);
}

void printbadinstruction(int d, int a){
	int n=sprintf(usb_tx_buf, "\n\r *BAD* %02x at %04x\n\r", d, a);
	for(int i=0;i<n;i++)
		writechar(usb_tx_buf[i]);
}

void patchinput(char *mem, int a){
	if (mem[a]==0xad && mem[a+1]==0xf0 && mem[a+2]==0xff ) {
#ifdef DEBUG
		writechar('P');
#endif
		mem[a]=0x42;
		mem[a+1]=0x1;
		mem[a+2]=0xea;
	}
}

void patchoutput(char *mem, int a){
	if (mem[a]==0x8d && mem[a+1]==0xf0 && mem[a+2]==0xff ) {
		writechar('Q');
		mem[a]=0x42;
		mem[a+1]=0x0;
		mem[a+2]=0xea;
	}
}

char mem[65536];

void print6502state(int a, int x, int y, int s, int pc, int p, int ir){
	int n=sprintf(
		usb_tx_buf,
		"IR: %02x m[e]: %02x PC: %04x A:%02x X:%02x Y:%02x S:%02x P(nv-bdizc):%02x",
		ir, mem[0xe], pc, a, x, y, s, p
		);
	writestring64(&usb_tx_buf[0], n);

	n=sprintf(
		usb_tx_buf,
		" Stack: [0x01ff..] %02x %02x %02x %02x\n\r",
		mem[0x1ff], mem[0x1fe], mem[0x1fd], mem[0x1fc]
		);
	writestring64(&usb_tx_buf[0], n);

}

int wdm_handler (int op, int acc){
	if (op == 0){	       /* output */
		/*
		int n=sprintf(usb_tx_buf, "\n\rOutput: %02x (%c)\n\r", c, c);
		for(int i=0;i<n;i++)
			writechar(usb_tx_buf[i]);
		*/
		if(acc=='\r')
			writechar('\n');
		writechar(acc);
		return(acc);  /* we are emulating a STA so we must preserve A */
	} else if (op == 1) {  /* blocking input */
		while (usb_rx_buf[0] == 0)
	                usbd_poll();
		char v=usb_rx_buf[0];
		usb_rx_buf[0]=0;
		if(v=='\n')
			v='\r'; /* convert to old-school serial port expectations */
		return(v);
	} else if (op == 0x54) {
		/* tracing control is done in emulator.S */
		return(acc);  /* we are emulating a NOP so we must preserve A */
	} else if (op == 0x74) {
		/* tracing control is done in emulator.S */
		return(acc);  /* we are emulating a NOP so we must preserve A */
	} else if (op == 0xff) {
		/* dump machine state */
                /* if only we knew how: we'd need to pass everything down to this function */
		return(acc);  /* we are emulating a NOP so we must preserve A */
	}
	return (0);
}

char testprog[] = {

	0xa9, 0x0f,              // LDA #
	0x85, 0x02,              // STA zp
	0xa5, 0x02,              // LDA zp
	0xad, 0x02, 0x00,        // LDA abs

	0xa9, 0x0e,              // LDA #
	0x8d, 0x02, 0x00,        // STA abs
	0xa5, 0x02,              // LDA zp
	0xad, 0x02, 0x00,        // LDA abs

        0xa2, 0xff, // LDX #$ff
        0x9a,       // TXS

/*
	0xa9, 0x03,              // LDA #
	0x6a,                    // ROR A
	0x6a,                    // ROR A
	0x6a,                    // ROR A
	0x6a,                    // ROR A

	0x2a,                    // ROL A
	0x2a,                    // ROL A
	0x2a,                    // ROL A
	0x2a,                    // ROL A

	0x4a,                    // LSR A
	0x4a,                    // LSR A
	0x4a,                    // LSR A
	0x4a,                    // LSR A

        0xa9, 0x60,              // LDA #  
	0x85, 0x0f,              // STA zp
	0x0a,                    // ASL A
	0x0a,                    // ASL A
	0x0a,                    // ASL A
	0x0a,                    // ASL A

	0x26, 0x0f,              // ROL zp
	0x26, 0x0f,              // ROL zp
	0x26, 0x0f,              // ROL zp
	0x26, 0x0f,              // ROL zp

	0x66, 0x0f,              // ROR zp
	0x66, 0x0f,              // ROR zp
	0x66, 0x0f,              // ROR zp
	0x66, 0x0f,              // ROR zp
*/

/*
        0xa9, 0x81,              // LDA #
        0xc9, 0x80,              // CMP #
        0xc9, 0x81,              // CMP #
        0xc9, 0x82,              // CMP #
        0xc9, 0x01,              // CMP #
        0xc9, 0x02,              // CMP #   @ a981c980c981c982c901c9026981c982

	0x69, 0x81,              // ADC #
	0xc9, 0x82,              // CMP #
*/


/*
	0xa2, 0xf0,              // LDX #
	0x20, 0x18, 0x02,        // JSR
	0xa2, 0x70,              // LDX #
	0x20, 0x18, 0x02,        // JSR
	0xa2, 0x80,              // LDX #
	0x20, 0x18, 0x02,        // JSR
	0xa2, 0x10,              // LDX #
	0x20, 0x18, 0x02,        // JSR
	0x2b,                    // ILL BAD

        0xa0, 0x00,              // LDY #
	0x84, 0x0f,              // STY zp
	0x8a,                    // TXA
        0x24, 0x0f,              // BIT zp

        0xa0, 0x40,              // LDY #
	0x84, 0x0f,              // STY zp
	0x8a,                    // TXA
        0x24, 0x0f,              // BIT zp

        0xa0, 0x80,              // LDY #
	0x84, 0x0f,              // STY zp
	0x8a,                    // TXA
        0x24, 0x0f,              // BIT zp

        0xa0, 0xc0,              // LDY #
	0x84, 0x0f,              // STY zp
	0x8a,                    // TXA
        0x24, 0x0f,              // BIT zp

	0x60,                    // RTS
*/

/*
        0xa2, 0xff, // LDX #$ff
        0x9a,       // TXS
        0x38,                    // SEC 
        0xa9, 0x88,              // LDA #
        0x8d, 0x00, 0x04,        // STA abs
        0xa9, 0x40,              // LDA #
        0x8d, 0x01, 0x04,        // STA abs
        0xa9, 0x00,              // LDA #
	0x8d, 0xfe, 0xff,        // STA abs
        0xa9, 0x04,              // LDA #
	0x8d, 0xff, 0xff,        // STA abs
        0x00,                    // BRK    a2ff9a38a9888d0004a9408d0104a9018dfffea9048dffff00e888
        0xe8,                    // INX @ operand of brk
        0x88,                    // DEY

        0x00,                    // BRK
*/

/*
        0xa9, 0x01,              // LDA #
        0x18,                    // CLC
        0x69, 0xc2,              // ADC #
        0x38,                    // SEC
        0x69, 0x01,              // ADC #   
        0x69, 0xc2,              // ADC #   a9011869c238690169c2

        0x00,                    // BRK

        0xa9, 0x01,              // LDA #
        0x18,                    // CLC
        0xe9, 0x00,              // SBC #

        0xa9, 0x01,              // LDA #
        0x18,                    // CLC
        0xe9, 0x01,              // SBC #

        0xa9, 0x01,              // LDA #
        0x18,                    // CLC
        0xe9, 0x02,              // SBC #


        0xa9, 0x01,              // LDA #
        0x38,                    // SEC
        0xe9, 0x00,              // SBC #

        0xa9, 0x01,              // LDA #
        0x38,                    // SEC
        0xe9, 0x01,              // SBC #

        0xa9, 0x01,              // LDA #
        0x38,                    // SEC
        0xe9, 0x02,              // SBC #


        0x00,                    // BRK
*/

/*
	0xa2, 0x00,              // LDX #$00
        0xa9, 0xf2,              // LDA #$F2
        0x38,                    // SEC
        0x69, 0xc2,              // ADC #$c2
        0xa9, 0x00,              // LDX #$00
        0x48,                    // PHA                                                                                                                                                                                                           
        0xa9, 0xff,              // LDX #$ff
        0x48,                    // PHA


        0xa2, 0xff, // LDX #$ff
        0x9a,       // TXS
        0xa9, 0x01,              // LDA #$01
        0x48,                    // PHA
        0xa9, 0x02,              // LDA #$02
        0x48,                    // PHA
        0xa9, 0x03,              // LDA #$03
        0x48,                    // PHA
        0x40,                    // RTI


        0xa2, 0x02,              // LDX #2
        0xca,                    // DEX
        0x10, 0xfd,              // BNE -3
        0xea,                    // NOP

* (derived from) MIT-licensed test program from visual6502.org
*

	0xa2, 0xff, // LDX #$ff
	0x9a,       // TXS
	0xa2, 0x40, // ldx #$40
	0x86, 0x0f, // stx $f
	0xa9, 0x00,              // LDA #$00
	0x20, 0x13, 0x02,        // JSR $0210  @ adjusted
	0x4c, 0x09, 0x02,        // JMP $0202  @ adjusted

	0x00, 0x00, 0x00, 0x40,

	0xe8,                    // INX
	0x88,                    // DEY
	0xe6, 0x0F,              // INC $0F

	0x48,       // pha
	0xa5, 0x0f, // lda $f
	0x42, 0x00, // wdm output
	0x68,       // pla

	0x38,                    // SEC
	0x69, 0x02,              // ADC #$02
	0x60,                    // RTS


*/
	0xea, // NOP
	0xa9, 0x45,              // LDA #'E'
	0x42, 0x00,   // WDM 00  - putc A to stdout (usb)
	0xa9, 0x44,              // LDA #'D'
	0x42, 0x00,   // WDM 00  - putc A to stdout (usb)

	0xea, // NOP
};

void top(){

	usb_rx_buf[0] = 0; /* poor effort at detecting incoming data */

/* on polling, the idea seems to be only to poll when we're ready to deal with input
   (no need to poll when outputting)
 */

	/* 2 million polls takes about a second and seems enough to allow us to send data
           (if we try to send too soon, the USB attachment doesn't happen)
         */
	for(int j=0;j<1024*1024;j++)
	        usbd_poll();
	writechar('H');
	writechar('i');
	writechar('\n');
	writechar('\r');

#ifdef TESTPROG
	/* we need to initialise the memory with something
           either a test program or a monitor
	 */

	for(uint i=0;i<sizeof(testprog);i++)
		mem[0x0200+i]=testprog[i];
	mem[0xfffc]=0x00;
	mem[0xfffd]=0x02;
#else

	/* copy a (whole or partial) memory image to the 6502 memory space */

	/* set a default reset vector for images which lack one */
	mem[0xfffc]=0x00;
	mem[0xfffd]=0xf8;

	char *p = MEMIMAGE;
	int len=MEMIMAGE_END-MEMIMAGE;
	for(int i=0x10000-len; i<0x10000; i++){
		mem[i] = *p++;
	}

	/* patch memory-mapped i/o to use WDM opcode */
	patchinput(&mem[0], 0xf84a);   /* supermon */
	patchoutput(&mem[0], 0xf846);
	patchinput(&mem[0], 0xC833);   /* ehbasic */
	patchoutput(&mem[0], 0xC82F);
	patchinput(&mem[0], 0x1BBB);   /* figforth */
	patchoutput(&mem[0], 0x1BC1);
	patchinput(&mem[0], 0xffd4);   /* tube-like OS for HiBASIC */
	patchoutput(&mem[0], 0xff29);

#ifdef DEBUG
        printhex8(mem[0xf800]); /* just for confidence */
        printhex8(mem[0xf801]);
        printhex8(mem[0xf802]);
        printhex8(mem[0xf803]);
        printhex8(mem[0xb800]); /* just for confidence */
        printhex8(mem[0xb801]);
        printhex8(mem[0xb802]);
        printhex8(mem[0xb803]);
#endif
#endif

	int resetv = mem[0xfffc] + 256*mem[0xfffd];
	emulator(resetv, mem);

}
