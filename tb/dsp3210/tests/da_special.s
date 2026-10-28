/* The special functions (4.6, 8.2.4, 8.2.5): conversions, round, seed and
   the zero-latency conditional loads.  Each result is written by its own
   instruction's Z (the integer results are formatted in memory only so). */
	r1 = (ushort24) FLT
	r2 = (ushort24) 0x1000
	r3 = (ushort24) INT
	r5 = (short) 0
	dauc = r5                      // round to nearest, mu-law
	nop
	nop
	// int32: round to nearest (a one in the first fraction bit: +1)
	*r2++ = a0 = int32(*r1++)      // 2.5 -> 3            //! expect 0x1000 0x00000003
	*r2++ = a0 = int32(*r1++)      // -2.5 -> -2          //! expect 0x1004 0xFFFFFFFE
	*r2++ = a0 = int32(*r1++)      // 1.25 -> 1           //! expect 0x1008 0x00000001
	*r2++ = a0 = int32(*r1++)      // 3e9 -> saturated    //! expect 0x100C 0x7FFFFFFF
	*r2++ = a0 = int32(*r1++)      // -3e9 -> saturated   //! expect 0x1010 0x80000000
	// toward -inf (dauc[5:4] 01)
	r1 = (ushort24) FLT
	r5 = (short) 0x10
	dauc = r5
	nop
	*r2++ = a0 = int32(*r1++)      // 2.5 -> 2            //! expect 0x1014 0x00000002
	*r2++ = a0 = int32(*r1++)      // -2.5 -> -3          //! expect 0x1018 0xFFFFFFFD
	// toward 0 (11)
	r1 = (ushort24) FLT
	r5 = (short) 0x30
	dauc = r5
	nop
	*r2++ = a0 = int32(*r1++)      // 2.5 -> 2            //! expect 0x101C 0x00000002
	*r2++ = a0 = int32(*r1++)      // -2.5 -> -2          //! expect 0x1020 0xFFFFFFFE
	r5 = (short) 0
	dauc = r5
	nop
	// float32: a 32-bit integer to float
	*r2++ = a1 = float32(*r3++)    // 12                  //! expect 0x1024 0x40000083
	*r2++ = a1 = float32(*r3++)    // -8                  //! expect 0x1028 0x80000082
	*r2++ = a1 = float32(*r3++)    // 0                   //! expect 0x102C 0x00000000
	// float16: a half-word (+2), sign extended
	*r2++ = a1 = float16(*r3++)    // 0xFFFD: -3          //! expect 0x1030 0xC0000081
	*r2++ = a1 = float16(*r3++)    // 0x0021: 33          //! expect 0x1034 0x04000085
	// int16: to a half-word (Z +2)
	r1 = (ushort24) F300
	r4 = (ushort24) 0x1100
	*r4++ = a2 = int16(*r1++)      // 300.7 -> 301
	*r4++ = a2 = int16(*r1++)      // 40000 -> 0x7fff     //! expect 0x1100 0x012D7FFF
	*r4++ = a2 = int16(*r1++)      // -40000 -> 0x8000
	*r4++ = a2 = int16(*r1++)      // -5 -> 0xfffb        //! expect 0x1104 0x8000FFFB
	// ieee / dsp
	r1 = (ushort24) IEEE
	*r2++ = a3 = ieee(*r1++)       // 1.0                 //! expect 0x1038 0x3F800000
	*r2++ = a3 = ieee(*r1++)       // -2.5                //! expect 0x103C 0xC0200000
	*r2++ = a3 = ieee(*r1++)       // 0                   //! expect 0x1040 0x00000000
	*r2++ = a3 = dsp(*r1++)        // pi                  //! expect 0x1044 0x490FDB81
	*r2++ = a3 = dsp(*r1++)        // -1.0                //! expect 0x1048 0x8000007F
	*r2++ = a3 = dsp(*r1++)        // +inf -> 0x7fffffff  //! expect 0x104C 0x7FFFFFFF
	*r2++ = a3 = dsp(*r1++)        // -inf -> 0x800000ff  //! expect 0x1050 0x800000FF
	*r2++ = a3 = dsp(*r1++)        // a denormal -> 0     //! expect 0x1054 0x00000000
	// round: 40 bits to 32, to nearest, a tie to the greater value
	r1 = (ushort24) RND
	r8 = (ushort24) RND + 8
	a0 = *r1 * *r1                 // (1 + 2^-12)^2 = 1 + 2^-11 + 2^-24 (a guard bit)
	a1 = *r1 * *r8                 // -(1 + 2^-12) * (1 + 2^-12)
	nop
	nop
	nop
	*r2++ = a2 = round(a0)         //! expect 0x1058 0x00100180
	*r2++ = a2 = a0                // stored: truncated   //! expect 0x105C 0x00100080
	*r2++ = a2 = round(a1)         // the tie up: -(1 + 2^-11)      //! expect 0x1060 0xFFF00080
	*r2++ = a2 = a1                // truncated toward -inf         //! expect 0x1064 0xFFEFFF80
	// seed: every bit but the sign inverted
	r1 = (ushort24) F2
	*r2++ = a2 = seed(*r1)         //! expect 0x1068 0x7FFFFF7E
	// ic / oc: mu-law (dauc 0)
	r1 = (ushort24) BYTES
	r4 = (ushort24) 0x1200
	*r2++ = a0 = ic(*r1++)         // 0xff: 0             //! expect 0x106C 0x00000000
	*r2++ = a0 = ic(*r1++)         // 0x80: 4015.5        //! expect 0x1070 0x7AF8008B
	*r2++ = a0 = ic(*r1++)         // 0x00: -4015.5       //! expect 0x1074 0x8508008B
	*r2++ = a0 = ic(*r1++)         // 0xef: 16.5          //! expect 0x1078 0x04000084
	nop
	nop
	nop
	*r4++ = a1 = oc(a0)            // 16.5 -> 0xef (Z +1)
	r6 = (ushort24) BIG
	*r4++ = a1 = oc(*r6)           // 1e6: saturated 0x80
	*r4++ = a1 = oc(*r1)           // 0.0 -> 0xff (BYTES + 4); the dauc write two later is not seen
	// A-law (dauc 3)
	r5 = (short) 3
	dauc = r5
	nop
	r1 = (ushort24) ABYTES
	*r2++ = a0 = ic(*r1++)         // 0xd5: 1.0           //! expect 0x107C 0x00000080
	*r2++ = a0 = ic(*r1++)         // 0xc5: 33.0          //! expect 0x1080 0x04000085
	nop
	nop
	nop
	*r4++ = a1 = oc(a0)            // 33.0 -> 0xc5        //! expect 0x1200 0xEF80FFC5
	// unsigned linear bytes (dauc[3] out, dauc[2] in)
	r5 = (short) 0x0C
	dauc = r5
	nop
	*r2++ = a0 = ic(*r1++)         // 200                 //! expect 0x1084 0x48000087
	r1 = (ushort24) LIN
	r4 = (ushort24) 0x1204
	*r4++ = a1 = oc(*r1++)         // 37.6 -> 38
	*r4++ = a1 = oc(*r1++)         // 300 -> 255
	*r4++ = a1 = oc(*r1++)         // -5 -> 0
	r5 = (short) 0x1C              // toward -inf
	dauc = r5
	nop
	*r4++ = a1 = oc(*r1++)         // 37.6 -> 37          //! expect 0x1204 0x26FF0025
	// an accumulator's integer operand: its top bits (int32's result, ic's byte)
	r5 = (short) 0
	dauc = r5
	r1 = (ushort24) F12
	a0 = int32(*r1)                // a0 = 12 in its top 32 bits
	nop
	nop
	nop
	*r2++ = a1 = float32(a0)       // 12.0                //! expect 0x1088 0x40000083
	// ifalt / ifaeq / ifagt: the last DA result's condition, no latency
	r1 = (ushort24) FLT
	r6 = (ushort24) F12
	a0 = *r1                       // 2.5: positive
	*r2++ = a1 = ifagt(*r6)        // taken: 12.0         //! expect 0x108C 0x40000083
	*r2++ = a2 = ifalt(*r6)        // not: the old a2 stored (dauc[6] 0) //! expect 0x1090 0x7FFFFF7E
	a3 = *r1++ - *r1               // 2.5 - 2.5 = 0: eq (the conditionals set no flags)
	*r2++ = a3 = ifaeq(*r6)        // taken               //! expect 0x1094 0x40000083
	r5 = (short) 0x40
	dauc = r5
	nop
	r7 = (ushort24) 0x1300
	*r7++ = a2 = ifalt(*r6)        // not taken, not written, r7 still advanced
	*r7++ = a2 = ifaeq(*r6)        // taken: written at 0x1304             //! expect 0x1304 0x40000083
	r10 = (ushort24) 0x0FFFF0
	r11 = (ushort24) 0x00D0E5
	r11 = r11 <<| 0x600D
	*r10 = r11
L9:	pcgoto L9
	nop
	.align 4
FLT:	.float 2.5, -2.5, 1.25, 3e9, -3e9
INT:	.long 12, -8, 0
	.long 0xFFFD0021               // two half-words
F300:	.float 300.7, 40000.0, -40000.0, -5.0
IEEE:	.float 1.0, -2.5, 0.0
	.long 0x40490FDB, 0xBF800000, 0x7F800000, 0xFF800000, 0x00012345
RND:	.long 0x00080080, 0x00080080, 0xFFF80080
BYTES:	.long 0xFF8000EF, 0
ABYTES:	.long 0xD5C5C800
BIG:	.float 1000000.0
LIN:	.float 37.6, 300.0, -5.0, 37.6
F12:	.float 12.0
F2:	.float 2.0
//! expect 0x1300 0x00000000
