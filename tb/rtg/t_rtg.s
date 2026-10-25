; The RTG driver (extra/rtg_driver/MiSTer.card.asm, as built) on the AP68040
; bench: SetGC then SetPanning, as Picasso96 calls them, with the board's
; registers in RAM to read back what the driver wrote.  The scan-out address
; is the bitmap's start in the board's memory plus YOffset rows of the
; bitmap's own width and XOffset pixels (WinUAE picasso_SetPanning), and the
; stride is the bitmap's bytes per row: a virtual screen wider than the mode
; and a scrolled one.  The offsets go back to the BoardInfo; D2-D7 are kept.
; Progress in $F100 (the failing case), $600D/$BAD0 in $F102.

BI      equ     $8000                   ; struct BoardInfo
MI      equ     $9000                   ; struct ModeInfo
REGS    equ     $A000                   ; the board's registers (RAM here)
MEMBASE equ     $40000000               ; the board's memory as the Amiga sees it

        org     0
        dc.l    $3400,t_start
        rept    254
        dc.l    t_fail
        endr

        org     $400
t_start:
        move.w  #$2700,sr
        moveq   #0,d0
        movec   d0,cacr
        movec   d0,tc
        lea     BI,a0
        move.l  #REGS,PSSO_BoardInfo_RegisterBase(a0)
        move.l  #MEMBASE,PSSO_BoardInfo_MemoryBase(a0)

        lea     cases(pc),a5
        moveq   #1,d6
.next:  tst.w   (a5)
        beq     t_pass
        move.w  d6,($F100).l
        ; the mode: width, height, depth
        lea     MI,a1
        move.w  (a5)+,PSSO_ModeInfo_Width(a1)
        move.w  #480,PSSO_ModeInfo_Height(a1)
        move.w  (a5)+,d0
        move.b  d0,PSSO_ModeInfo_Depth(a1)
        lea     BI,a0
        jsr     SetGC
        ; the bitmap: its start offset, width, the view's offsets, the format
        lea     BI,a0
        move.l  (a5)+,d0
        add.l   #MEMBASE,d0
        movea.l d0,a1
        move.w  (a5)+,d0
        move.w  (a5)+,d1
        move.w  (a5)+,d2
        move.l  (a5)+,d7
        move.l  #$11112222,d3
        move.l  #$33334444,d4
        movem.w d1-d2,-(sp)
        jsr     SetPanning
        movem.w (sp)+,d1-d2
        ; the address, the stride, the offsets in the BoardInfo, D2-D4 kept
        move.l  (REGS+REG_ADDRESS).l,d0
        cmp.l   (a5)+,d0
        bne     t_fail
        move.w  (REGS+REG_STRIDE).l,d0
        cmp.w   (a5)+,d0
        bne     t_fail
        lea     BI,a0
        cmp.w   PSSO_BoardInfo_XOffset(a0),d1
        bne     t_fail
        cmp.w   PSSO_BoardInfo_YOffset(a0),d2
        bne     t_fail
        cmp.l   #$11112222,d3
        bne     t_fail
        cmp.l   #$33334444,d4
        bne     t_fail
        addq.w  #1,d6
        bra     .next

t_pass:
        move.w  #$600D,($F102).l
        stop    #$2700
t_fail:
        move.w  #$BAD0,($F102).l
        stop    #$2700

; mode width, depth; bitmap start (in the board), width, XOffset, YOffset,
; RGBFTYPE; the scan-out address and stride expected
cases:
        ; the bitmap the mode's size, no offsets
        dc.w    640,8
        dc.l    $1000
        dc.w    640,0,0
        dc.l    1                       ; RGBFB_CLUT
        dc.l    $27001000
        dc.w    640
        ; scrolled: 7 rows and 13 pixels in
        dc.w    640,8
        dc.l    $1000
        dc.w    640,13,7
        dc.l    1
        dc.l    $27001000+7*640+13
        dc.w    640
        ; a virtual screen 1024 wide on a 640 mode
        dc.w    640,8
        dc.l    $1000
        dc.w    1024,0,0
        dc.l    1
        dc.l    $27001000
        dc.w    1024
        ; and scrolled in it
        dc.w    640,8
        dc.l    $1000
        dc.w    1024,300,200
        dc.l    1
        dc.l    $27001000+200*1024+300
        dc.w    1024
        ; 32-bit ARGB, 800 wide on a 640 mode, 5 pixels and 3 rows in
        dc.w    640,32
        dc.l    $20000
        dc.w    800,5,3
        dc.l    6                       ; RGBFB_A8R8G8B8
        dc.l    $27020000+3*3200+5*4
        dc.w    3200
        ; 16-bit RGB565, 1280 wide, 100 pixels and 200 rows in
        dc.w    800,16
        dc.l    $40000
        dc.w    1280,100,200
        dc.l    10                      ; RGBFB_R5G6B5
        dc.l    $27040000+200*2560+100*2
        dc.w    2560
        ; 24-bit RGB, 1024 wide on a 1024 mode, no offsets
        dc.w    1024,24
        dc.l    $80000
        dc.w    1024,0,0
        dc.l    2                       ; RGBFB_R8G8B8
        dc.l    $27080000
        dc.w    3072
        dc.w    0

        include "MiSTer.card.asm"
