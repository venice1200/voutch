;==============================================================
; K-1008 VISABLE MEMORY - Character Display Routines
; MTU K-1008 mapped at $C000-$DFFF but easily configurable
; by chaging the VMBASE value to your needs
;
; Display: 320 x 200 pixels, 40 bytes/scanline
; Text:    40 columns x 25 rows, 8x8 pixel characters
;          Bit 7 of each byte = leftmost pixel (MSB-first)
;
; USAGE - modeled after KIM-1 OUTCH ($1EA0):
;
;   JSR  VINIT      ; once at startup: clear screen, home cursor
;
;   LDA  #'H'
;   JSR  VOUTCH     ; display character, advance cursor
;
;   LDA  #$0D       ; move to next line (scrolls at bottom)
;   JSR  VOUTCH
;
; Supported input values:
;   $08        -> backspace (move cursor back one column; wraps to prev row)
;   $0A / $0D  -> newline (column 0, next row; scrolls at bottom)
;   $20-$5F    -> printable: space, 0-9, A-Z, punctuation
;   $61-$7A    -> lowercase a-z (silently upcased to A-Z)
;   All other values are ignored.
;
; Zero page used ($F0-$F5) - change equates below if needed:
;   VCOL   $F0   cursor column  (0-39)
;   VROW   $F1   cursor row     (0-24)
;   VPTR   $F2   font read ptr, lo byte  }
;   VPTR1  $F3   font read ptr, hi byte  } 16-bit
;   VDST   $F4   screen write ptr, lo    }
;   VDST1  $F5   screen write ptr, hi    } 16-bit
;
; Clobbers: A, X, Y
;==============================================================

; ---- Hardware config (match your DIP switch setting) -------
VMBASE  = $8000         ; Full Video RAM Base  ($C000-$DFFF)
VMBASEH = >VMBASE       ; Calculated Video RAM Base High Byte
VWIDTH  = 40            ; bytes per pixel scanline (320/8)
VCOLS   = 40            ; text columns
VROWS   = 25            ; text rows  (25 * 8 = 200 scanlines exactly)

; ---- Zero page allocation ----------------------------------
; KIM-1 monitor owns $00-$06 and $F0-$FF.  Safe user range: $07-$EF.
VCOL    = $E0           ; current column  (0 to VCOLS-1)
VROW    = $E1           ; current row     (0 to VROWS-1)
VPTR    = $E2           ; font pointer lo
VPTR1   = $E3           ; font pointer hi
VDST    = $E4           ; screen dest lo
VDST1   = $E5           ; screen dest hi
BUFF    = $E6           ; Buffer Byte

;==============================================================
; VINIT - clear display and home cursor.
;         Call once at startup before using VOUTCH.
;==============================================================
VINIT:
        ;----------------------------------------------------
        PHA                     ; Rescue A
        TXA                     ; Rescue X
        PHA                     ;
        TYA                     ; Rescue Y
        PHA                     ;
        ;----------------------------------------------------
        LDA  #0
        STA  VCOL
        STA  VROW
        ; fall through to VCLR

;==============================================================
; VCLR - fill entire video RAM with $00 (all pixels off).
;        Does NOT reset cursor position.
;==============================================================
VCLR:
        LDA  #<VMBASE           ; VM Base Low Byte
        STA  VDST
        LDA  #>VMBASE           ; VM Base High Byte
        STA  VDST1
        LDA  #0                 ; fill value: black
        LDX  #$20               ; 32 pages x 256 bytes = 8192
        LDY  #0
VCLR1:  STA  (VDST),Y
        INY
        BNE  VCLR1              ; inner: 256 bytes per page
        INC  VDST1
        DEX
        BNE  VCLR1              ; outer: 32 pages
        ;----------------------------------------------------
        PLA                     ;
        TAY                     ; Restore Y
        PLA                     ; 
        TAX                     ; Restore X
        PLA                     ; Restore A
        ;----------------------------------------------------
        RTS

;==============================================================
; VOUTCH - write ASCII character in A to display at cursor.
;          Advances cursor; wraps at column 40; scrolls at
;          row 25.  Modeled after KIM-1 OUTCH ($1EA0).
;
; Entry:  A = ASCII character
; Exit:   A, X, Y modified; VCOL/VROW updated
;==============================================================
VOUTCH:
        STA BUFF                ; Rescue A to BUFFER
        ;----------------------------------------------------
        TXA                     ; Rescue X
        PHA                     ;
        TYA                     ; Rescue Y
        PHA                     ;
        ; ---- backspace ------------------------------------
        LDA BUFF                ; Restore A from BUFFER
        CMP  #$08
        BNE  VNOTBS
        JMP  VBKSP
VNOTBS:
        ; ---- newline: CR or LF ----------------------------
        CMP  #$0D
        BEQ  VCRLF
        CMP  #$0A
        BEQ  VCRLF

        ; ---- ignore control characters below space --------
        CMP  #$20
        BCC  VOUT_RTS

        ; ---- lowercase a-z -> A-Z -------------------------
        CMP  #$61               ; below 'a'?
        BCC  VNOTLWR
        CMP  #$7B               ; above 'z'?
        BCS  VNOTLWR
        SEC
        SBC  #$20               ; fold to uppercase
VNOTLWR:
        ; ---- clamp: only $20-$5F has font entries ---------
        CMP  #$60
        BCS  VOUT_RTS           ; $60 and above: ignore

        ; ---- convert to font index 0..63 ------------------
        SEC
        SBC  #$20               ; index = char - $20
        TAX                     ; save index in X

        ; ---- VPTR = VFONT + index*8  (9-bit offset) -------
        ; Three left-shifts of index; carry bits accumulate in VPTR1.
        ; Max: index=63, 63*8=504=$01F8 -> lo=$F8, hi=$01
        LDA  #0
        STA  VPTR1              ; clear hi byte before shifts
        TXA                     ; restore index to A
        ASL  A                  ; *2
        ROL  VPTR1              ; carry -> VPTR1 bit 0
        ASL  A                  ; *4
        ROL  VPTR1
        ASL  A                  ; *8  carry -> VPTR1
        ROL  VPTR1
        ; A = low byte of (index*8)
        CLC
        ADC  #<VFONT
        STA  VPTR
        LDA  VPTR1
        ADC  #>VFONT
        STA  VPTR1

        ; ---- VDST = VROWTBL[VROW] + VCOL ------------------
        ; VROWTBL holds 16-bit row-start addresses as lo/hi pairs.
        LDA  VROW
        ASL  A                  ; *2: table stride = 2 bytes/entry
        TAX
        LDA  VROWTBL,X          ; lo byte of row base address
        CLC
        ADC  VCOL               ; add column offset
        STA  VDST
        LDA  VROWTBL+1,X        ; hi byte of row base address
        ADC  #0                 ; absorb carry from column add
        STA  VDST1

        ; ---- render 8 scanlines ----------------------------
        ; Y=0 throughout; used only for (ptr),Y indirect mode.
        ; Each pass: read 1 font byte, write to screen,
        ;            VPTR += 1, VDST += VWIDTH (40).
        LDY  #0
        LDX  #8                 ; 8 scanlines per character row
VREND:
        LDA  (VPTR),Y           ; read font scanline byte  (Y=0)
        STA  (VDST),Y           ; write to screen          (Y=0)

        INC  VPTR               ; advance font ptr +1
        BNE  VNXT_DST
        INC  VPTR1

VNXT_DST:
        LDA  VDST               ; advance screen ptr +40
        CLC
        ADC  #VWIDTH
        STA  VDST
        BCC  VREND_CHK
        INC  VDST1

VREND_CHK:
        DEX
        BNE  VREND

        ; ---- advance cursor column ------------------------
        INC  VCOL
        LDA  VCOL
        CMP  #VCOLS             ; wrapped past column 39?
        BCC  VOUT_RTS           ; no: done

        ; column wrapped -> newline
VCRLF:
        LDA  #0
        STA  VCOL               ; reset to column 0
        INC  VROW
        LDA  VROW
        CMP  #VROWS             ; past last row?
        BCC  VOUT_RTS           ; no: done

        ; past last row -> scroll up
        JSR  VSCROLL
        LDA  #VROWS-1           ; pin cursor to bottom row
        STA  VROW

VOUT_RTS:
        ;----------------------------------------------------
        PLA                     ;
        TAY                     ; Restore Y
        PLA                     ; 
        TAX                     ; Restore X
        ;----------------------------------------------------
        RTS

;==============================================================
; VBKSP - move cursor back one column.
;         If already at column 0, wraps to column 39 of the
;         previous row.  Does nothing if at home (0,0).
;         Clobbers: A
;==============================================================
VBKSP:
        LDA  VCOL
        BNE  VBKSP_DEC          ; col > 0: just back up
        LDA  VROW
        BEQ  VOUT_RTS            ; col=0 row=0: already home, ignore
        DEC  VROW                ; move to end of previous row
        LDA  #VCOLS-1
        STA  VCOL
        RTS
VBKSP_DEC:
        DEC  VCOL
        RTS

;==============================================================
; VSCROLL - scroll display up one character row (8 scanlines).
;           Clears the newly exposed bottom row.
;           Clobbers: A, X, Y, VPTR/VPTR1, VDST/VDST1
;==============================================================
VSCROLL:
        ; Copy rows 1..24 to rows 0..23
        ; Source: VMBASE + 320  = $C140  (start of row 1)
        ; Dest:   VMBASE        = $C000  (start of row 0)
        ; Length: 24 * 320 = 7680 bytes  = exactly 30 pages of 256

        LDA  #<(VMBASE + VWIDTH*8)
        STA  VPTR
        LDA  #>(VMBASE + VWIDTH*8)
        STA  VPTR1              ; source = $C140

        LDA  #<VMBASE
        STA  VDST
        LDA  #>VMBASE
        STA  VDST1              ; dest   = $C000

        LDX  #30                ; 30 pages * 256 bytes = 7680
        LDY  #0
VSCR1:
        LDA  (VPTR),Y
        STA  (VDST),Y
        INY
        BNE  VSCR1              ; loop 256 times per page
        INC  VPTR1
        INC  VDST1
        DEX
        BNE  VSCR1
        ; VDST now points to $DE00 = start of last char row

        ; Clear last row: $DE00-$DF3F (320 bytes = 256 + 64)
        LDA  #0
        LDY  #0
VSCR2:  STA  (VDST),Y          ; clear $DE00-$DEFF (256 bytes)
        INY
        BNE  VSCR2
        INC  VDST1              ; advance to $DF00
VSCR3:  STA  (VDST),Y          ; clear $DF00-$DF3F (64 bytes)
        INY
        CPY  #64
        BNE  VSCR3
        RTS

;==============================================================
; VROWTBL - start address of each text row, as lo/hi pairs.
;
; Row N base = VMBASE + N * 320  (N=0..24)
; Index with: LDA VROW / ASL A / TAX / LDA VROWTBL,X
; Note: VMBASE = VMBASEH*$100
;==============================================================
VROWTBL:
        ;Calculated Row values
        .byte $00,VMBASEH+$00     ; row  0  $C000
        .byte $40,VMBASEH+$01     ; row  1  $C140
        .byte $80,VMBASEH+$02     ; row  2  $C280
        .byte $C0,VMBASEH+$03     ; row  3  $C3C0
        .byte $00,VMBASEH+$05     ; row  4  $C500
        .byte $40,VMBASEH+$06     ; row  5  $C640
        .byte $80,VMBASEH+$07     ; row  6  $C780
        .byte $C0,VMBASEH+$08     ; row  7  $C8C0
        .byte $00,VMBASEH+$0A     ; row  8  $CA00
        .byte $40,VMBASEH+$0B     ; row  9  $CB40
        .byte $80,VMBASEH+$0C     ; row 10  $CC80
        .byte $C0,VMBASEH+$0D     ; row 11  $CDC0
        .byte $00,VMBASEH+$0F     ; row 12  $CF00
        .byte $40,VMBASEH+$10     ; row 13  $D040
        .byte $80,VMBASEH+$11     ; row 14  $D180
        .byte $C0,VMBASEH+$12     ; row 15  $D2C0
        .byte $00,VMBASEH+$14     ; row 16  $D400
        .byte $40,VMBASEH+$15     ; row 17  $D540
        .byte $80,VMBASEH+$16     ; row 18  $D680
        .byte $C0,VMBASEH+$17     ; row 19  $D7C0
        .byte $00,VMBASEH+$19     ; row 20  $D900
        .byte $40,VMBASEH+$1A     ; row 21  $DA40
        .byte $80,VMBASEH+$1B     ; row 22  $DB80
        .byte $C0,VMBASEH+$1C     ; row 23  $DCC0
        .byte $00,VMBASEH+$1E     ; row 24  $DE00

;==============================================================
; VFONT - 8x8 bitmap font, ASCII $20-$5F (64 characters)
;         8 bytes per character, top row first.
;         Bit 7 = leftmost pixel, bit 0 = rightmost pixel.
;
; Index = ASCII - $20   (so 'A'=$41, index=33)
;
; Lowercase input is upcased by VOUTCH before this lookup.
;==============================================================
VFONT:
; idx  0  $20  SPACE
        .byte $00,$00,$00,$00,$00,$00,$00,$00
; idx  1  $21  !
        .byte $18,$18,$18,$18,$18,$00,$18,$00
; idx  2  $22  "
        .byte $6C,$6C,$24,$00,$00,$00,$00,$00
; idx  3  $23  #
        .byte $36,$36,$7F,$36,$7F,$36,$36,$00
; idx  4  $24  $
        .byte $18,$3E,$60,$3C,$06,$7C,$18,$00
; idx  5  $25  %
        .byte $61,$62,$04,$0C,$10,$26,$43,$00
; idx  6  $26  &
        .byte $38,$6C,$6C,$38,$6D,$66,$3B,$00
; idx  7  $27  '
        .byte $18,$18,$30,$00,$00,$00,$00,$00
; idx  8  $28  (
        .byte $0C,$18,$30,$30,$30,$18,$0C,$00
; idx  9  $29  )
        .byte $30,$18,$0C,$0C,$0C,$18,$30,$00
; idx 10  $2A  *
        .byte $00,$66,$3C,$FF,$3C,$66,$00,$00
; idx 11  $2B  +
        .byte $00,$18,$18,$7E,$18,$18,$00,$00
; idx 12  $2C  ,
        .byte $00,$00,$00,$00,$00,$18,$18,$30
; idx 13  $2D  -
        .byte $00,$00,$00,$3C,$00,$00,$00,$00
; idx 14  $2E  .
        .byte $00,$00,$00,$00,$00,$18,$18,$00
; idx 15  $2F  /
        .byte $00,$03,$06,$0C,$18,$30,$60,$00
; idx 16  $30  0
        .byte $3C,$66,$6E,$76,$66,$66,$3C,$00
; idx 17  $31  1
        .byte $18,$38,$18,$18,$18,$18,$7E,$00
; idx 18  $32  2
        .byte $3C,$66,$06,$0C,$18,$30,$7E,$00
; idx 19  $33  3
        .byte $3C,$66,$06,$1C,$06,$66,$3C,$00
; idx 20  $34  4
        .byte $06,$0E,$1E,$66,$7F,$06,$06,$00
; idx 21  $35  5
        .byte $7E,$60,$7C,$06,$06,$66,$3C,$00
; idx 22  $36  6
        .byte $1C,$30,$60,$7C,$66,$66,$3C,$00
; idx 23  $37  7
        .byte $7E,$66,$0C,$18,$18,$18,$18,$00
; idx 24  $38  8
        .byte $3C,$66,$66,$3C,$66,$66,$3C,$00
; idx 25  $39  9
        .byte $3C,$66,$66,$3E,$06,$0C,$38,$00
; idx 26  $3A  :
        .byte $00,$18,$18,$00,$18,$18,$00,$00
; idx 27  $3B  ;
        .byte $00,$18,$18,$00,$18,$18,$30,$00
; idx 28  $3C  <
        .byte $06,$0C,$18,$30,$18,$0C,$06,$00
; idx 29  $3D  =
        .byte $00,$00,$3C,$00,$3C,$00,$00,$00
; idx 30  $3E  >
        .byte $60,$30,$18,$0C,$18,$30,$60,$00
; idx 31  $3F  ?
        .byte $3C,$66,$06,$0C,$18,$00,$18,$00
; idx 32  $40  @
        .byte $3E,$63,$6F,$69,$6F,$60,$3E,$00
; idx 33  $41  A
        .byte $18,$3C,$66,$7E,$66,$66,$66,$00
; idx 34  $42  B
        .byte $7C,$66,$66,$7C,$66,$66,$7C,$00
; idx 35  $43  C
        .byte $3C,$66,$60,$60,$60,$66,$3C,$00
; idx 36  $44  D
        .byte $78,$6C,$66,$66,$66,$6C,$78,$00
; idx 37  $45  E
        .byte $7E,$60,$60,$78,$60,$60,$7E,$00
; idx 38  $46  F
        .byte $7E,$60,$60,$78,$60,$60,$60,$00
; idx 39  $47  G
        .byte $3C,$66,$60,$6E,$66,$66,$3C,$00
; idx 40  $48  H
        .byte $66,$66,$66,$7E,$66,$66,$66,$00
; idx 41  $49  I
        .byte $3C,$18,$18,$18,$18,$18,$3C,$00
; idx 42  $4A  J
        .byte $1E,$0C,$0C,$0C,$0C,$6C,$38,$00
; idx 43  $4B  K
        .byte $66,$6C,$78,$70,$78,$6C,$66,$00
; idx 44  $4C  L
        .byte $60,$60,$60,$60,$60,$60,$7E,$00
; idx 45  $4D  M
        .byte $63,$77,$7F,$6B,$63,$63,$63,$00
; idx 46  $4E  N
        .byte $66,$76,$7E,$7E,$6E,$66,$66,$00
; idx 47  $4F  O
        .byte $3C,$66,$66,$66,$66,$66,$3C,$00
; idx 48  $50  P
        .byte $7C,$66,$66,$7C,$60,$60,$60,$00
; idx 49  $51  Q
        .byte $3C,$66,$66,$66,$76,$3C,$06,$00
; idx 50  $52  R
        .byte $7C,$66,$66,$7C,$6C,$66,$63,$00
; idx 51  $53  S
        .byte $3C,$66,$60,$3C,$06,$66,$3C,$00
; idx 52  $54  T
        .byte $7E,$18,$18,$18,$18,$18,$18,$00
; idx 53  $55  U
        .byte $66,$66,$66,$66,$66,$66,$3C,$00
; idx 54  $56  V
        .byte $66,$66,$66,$66,$66,$3C,$18,$00
; idx 55  $57  W
        .byte $63,$63,$63,$6B,$7F,$77,$63,$00
; idx 56  $58  X
        .byte $66,$66,$3C,$18,$3C,$66,$66,$00
; idx 57  $59  Y
        .byte $66,$66,$66,$3C,$18,$18,$18,$00
; idx 58  $5A  Z
        .byte $7E,$06,$0C,$18,$30,$60,$7E,$00
; idx 59  $5B  [
        .byte $3C,$30,$30,$30,$30,$30,$3C,$00
; idx 60  $5C  backslash
        .byte $00,$60,$30,$18,$0C,$06,$00,$00
; idx 61  $5D  ]
        .byte $3C,$0C,$0C,$0C,$0C,$0C,$3C,$00
; idx 62  $5E  ^
        .byte $08,$1C,$36,$63,$00,$00,$00,$00
; idx 63  $5F  _
        .byte $00,$00,$00,$00,$00,$00,$00,$FF

; Data totals:
;   VROWTBL : 25 rows * 2 bytes        =  50 bytes
;   VFONT   : 64 chars * 8 bytes       = 512 bytes
;   Code    : ~100 bytes (approx)
;   ZP      : 6 bytes ($F0-$F5)
