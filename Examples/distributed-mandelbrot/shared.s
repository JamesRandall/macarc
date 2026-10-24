; Distributed Mandelbrot: the routines the worker and the coordinator
; share, so the two compute, check and draw exactly alike. Position
; independent, and none of them touches R12 (each program's workspace).

; compute's parameter block
P_Out           * 0             ; where the counts go
P_Real          * 4             ; the tile's top left
P_Imag          * 8
P_StepReal      * 12
P_StepImag      * 16
P_Width         * 20
P_Height        * 24
P_Max           * 28
P_X             * 32            ; compute's own
P_Y             * 36
P_CR            * 40
P_CI            * 44
P_Size          * 48

; Compute a tile's counts: R0 points at the parameters (P_*).
; protocol.md's arithmetic, exactly: 4.28 fixed point, products of the
; magnitudes truncated, the sign put back after.
s_compute
        STMFD   R13!, {R0-R12, R14}
        MOV     R1, #0
        STR     R1, [R0, #P_X]
        STR     R1, [R0, #P_Y]
        LDR     R1, [R0, #P_Real]
        STR     R1, [R0, #P_CR]
        LDR     R1, [R0, #P_Imag]
        STR     R1, [R0, #P_CI]
s_pixel
        LDR     R12, [R13]      ; the parameters
        LDR     R2, [R12, #P_CR]
        LDR     R3, [R12, #P_CI]
        LDR     R5, [R12, #P_Max]
        MOV     R0, #0          ; x
        MOV     R1, #0          ; y
        MOV     R4, #0          ; n
s_iterate
        MOVS    R6, R0
        RSBMI   R6, R6, #0      ; |x|
        MOVS    R7, R1
        RSBMI   R7, R7, #0      ; |y|
        CMP     R6, #Two
        CMPLO   R7, #Two
        BHS     s_escaped
        ; x2 = |x|^2 >> 28 (|x| < 2^29, so the square's under 2^58)
        MOV     R9, R6, LSR #16
        BIC     R10, R6, R9, LSL #16
        MUL     R8, R10, R10    ; lo * lo
        MUL     R11, R9, R10    ; hi * lo (twice, below)
        MUL     R14, R9, R9     ; hi * hi
        ADDS    R8, R8, R11, LSL #17
        MOV     R11, R11, LSR #15
        ADC     R11, R11, R14
        MOV     R8, R8, LSR #28
        ORR     R8, R8, R11, LSL #4
        ; y2 = |y|^2 >> 28
        MOV     R9, R7, LSR #16
        BIC     R10, R7, R9, LSL #16
        MUL     R12, R10, R10
        MUL     R11, R9, R10
        MUL     R14, R9, R9
        ADDS    R12, R12, R11, LSL #17
        MOV     R11, R11, LSR #15
        ADC     R11, R11, R14
        MOV     R12, R12, LSR #28
        ORR     R12, R12, R11, LSL #4
        ADD     R14, R8, R12
        CMP     R14, #Four
        BHI     s_escaped
        ; xy = |x| |y| >> 28, with the sign of x y
        MOV     R9, R6, LSR #16
        BIC     R10, R6, R9, LSL #16
        MOV     R11, R7, LSR #16
        BIC     R7, R7, R11, LSL #16
        MUL     R6, R10, R7     ; lo * lo
        MUL     R14, R9, R7     ; the middle terms
        MLA     R14, R11, R10, R14
        MUL     R7, R9, R11     ; hi * hi
        ADDS    R6, R6, R14, LSL #16
        MOV     R14, R14, LSR #16
        ADC     R14, R14, R7
        MOV     R6, R6, LSR #28
        ORR     R6, R6, R14, LSL #4
        TEQ     R0, R1
        RSBMI   R6, R6, #0
        ADD     R1, R3, R6, LSL #1      ; y = 2xy + ci
        SUB     R0, R8, R12
        ADD     R0, R0, R2              ; x = x2 - y2 + cr
        ADD     R4, R4, #1
        CMP     R4, R5
        BLT     s_iterate
s_escaped
        LDR     R12, [R13]
        LDR     R0, [R12, #P_Out]
        STRB    R4, [R0], #1
        STR     R0, [R12, #P_Out]
        LDR     R0, [R12, #P_X]
        ADD     R0, R0, #1
        LDR     R1, [R12, #P_Width]
        CMP     R0, R1
        BEQ     s_row_done
        STR     R0, [R12, #P_X]
        LDR     R1, [R12, #P_CR]
        LDR     R2, [R12, #P_StepReal]
        ADD     R1, R1, R2
        STR     R1, [R12, #P_CR]
        B       s_pixel
s_row_done
        MOV     R0, #0
        STR     R0, [R12, #P_X]
        LDR     R1, [R12, #P_Real]
        STR     R1, [R12, #P_CR]
        LDR     R1, [R12, #P_CI]
        LDR     R2, [R12, #P_StepImag]
        ADD     R1, R1, R2
        STR     R1, [R12, #P_CI]
        LDR     R0, [R12, #P_Y]
        ADD     R0, R0, #1
        STR     R0, [R12, #P_Y]
        LDR     R1, [R12, #P_Height]
        CMP     R0, R1
        BLT     s_pixel
        LDMFD   R13!, {R0-R12, PC}

; Draw a tile: R0 counts, R1 x, R2 y (in the picture), R3 width (a
; multiple of 8), R4 height, R5 the maximum, R6 the screen, R7 the band
; table. Eight 4-bit pixels a word, the leftmost in the low bits.
s_draw
        STMFD   R13!, {R0-R11, R14}
        ADD     R2, R2, #ImageTop
        MOV     R8, #BytesPerRow
        MLA     R6, R2, R8, R6
        ADD     R6, R6, R1, LSR #1      ; the tile's top left
s_draw_row
        MOV     R8, R3                  ; pixels left in the row
        MOV     R9, R6
s_draw_word
        MOV     R10, #0
        MOV     R11, #0                 ; shift
s_draw_pixel
        LDRB    R1, [R0], #1
        CMP     R1, R5
        MOVEQ   R1, #0
        LDRNEB  R1, [R7, R1]
        ORR     R10, R10, R1, LSL R11
        ADD     R11, R11, #4
        CMP     R11, #32
        BLT     s_draw_pixel
        STR     R10, [R9], #4
        SUBS    R8, R8, #8
        BGT     s_draw_word
        ADD     R6, R6, #BytesPerRow
        SUBS    R4, R4, #1
        BGT     s_draw_row
        LDMFD   R13!, {R0-R11, PC}

; The band table at R0: count n has colour 1 + (n - 1) MOD 14
s_make_bands
        STMFD   R13!, {R0-R2, R14}
        MOV     R1, #0
        STRB    R1, [R0], #1
        MOV     R2, #1                  ; n = 1 ...
        MOV     R1, #1                  ; ... has colour 1
s_band
        STRB    R1, [R0], #1
        ADD     R1, R1, #1
        CMP     R1, #Bands + 1
        MOVEQ   R1, #1
        ADD     R2, R2, #1
        CMP     R2, #256
        BLT     s_band
        LDMFD   R13!, {R0-R2, PC}

; MODE 12, the palette, no cursor; the screen's address goes to [R1]
s_screen
        STMFD   R13!, {R0-R2, R14}
        MOV     R2, R1
        ADR     R0, s_mode
        MOV     R1, #s_mode_end - s_mode
        SWI     XOS_WriteN
        MOV     R0, #0
        BL      s_palette
        ADR     R0, s_screen_var
        MOV     R1, R2
        SWI     XOS_ReadVduVariables
        LDMFD   R13!, {R0-R2, PC}
s_screen_var
        EQUD    148, -1
s_mode
        EQUB    22, ScreenMode
        EQUB    23, 1, 0, 0, 0, 0, 0, 0, 0, 0   ; no cursor
        EQUB    19, 0, 16, 0, 0, 0
        EQUB    19, TextColour, 16, 255, 255, 255
        EQUB    17, TextColour, 17, 128
s_mode_end
        ALIGN

; Set the bands' colours, turned R0 places (0-13): the colour cycling
s_palette
        STMFD   R13!, {R0-R5, R14}
        MOV     R4, R0
        MOV     R5, #1                  ; colour
s_palette_one
        MOV     R0, #19
        SWI     XOS_WriteC
        MOV     R0, R5
        SWI     XOS_WriteC
        MOV     R0, #16
        SWI     XOS_WriteC
        SUB     R1, R5, #1
        ADD     R1, R1, R4
        CMP     R1, #Bands
        SUBHS   R1, R1, #Bands
        ADD     R1, R1, R1, LSL #1
        ADR     R2, s_colours
        ADD     R2, R2, R1
        LDRB    R0, [R2], #1
        SWI     XOS_WriteC
        LDRB    R0, [R2], #1
        SWI     XOS_WriteC
        LDRB    R0, [R2], #1
        SWI     XOS_WriteC
        ADD     R5, R5, #1
        CMP     R5, #Bands + 1
        BLT     s_palette_one
        LDMFD   R13!, {R0-R5, PC}
s_colours
        EQUB    0, 32, 128,   0, 80, 192,   0, 144, 224,   0, 208, 240
        EQUB    128, 240, 255,   240, 255, 224,   255, 240, 128,   255, 200, 0
        EQUB    255, 144, 0,   240, 80, 0,   208, 32, 32,   176, 0, 96
        EQUB    112, 0, 144,   48, 0, 128
        ALIGN

; Clear the picture: R0 the screen
s_clear
        STMFD   R13!, {R0-R2, R14}
        ADD     R0, R0, #ImageTop * BytesPerRow
        MOV     R1, #ImageHeight * BytesPerRow
        MOV     R2, #0
s_clear_word
        STR     R2, [R0], #4
        SUBS    R1, R1, #4
        BGT     s_clear_word
        LDMFD   R13!, {R0-R2, PC}

; Move the text cursor to column R0, row R1 (VDU 31: not in a string
; for OS_Write0, whose zeros would end it)
s_tab
        STMFD   R13!, {R0, R14}
        MOV     R0, #31
        SWI     XOS_WriteC
        LDR     R0, [R13]
        SWI     XOS_WriteC
        MOV     R0, R1
        SWI     XOS_WriteC
        LDMFD   R13!, {R0, PC}

; Print R0 in decimal, using the 16 bytes at R1
s_number
        STMFD   R13!, {R0-R2, R14}
        MOV     R2, #16
        SWI     XOS_ConvertCardinal4
        SWI     XOS_Write0
        LDMFD   R13!, {R0-R2, PC}

; Check a received message: R0 buffer, R1 length. Returns its type in R0,
; or 0 if a receiver ignores it (protocol.md: magic, version, lengths).
s_check
        STMFD   R13!, {R1-R3, R14}
        CMP     R1, #HdrSize
        BLT     s_check_no
        LDRB    R2, [R0, #HdrMagic]
        CMP     R2, #'M'
        LDREQB  R2, [R0, #HdrMagic + 1]
        CMPEQ   R2, #'A'
        LDREQB  R2, [R0, #HdrVersion]
        CMPEQ   R2, #Version
        BNE     s_check_no
        LDRB    R2, [R0, #HdrLength]
        LDRB    R3, [R0, #HdrLength + 1]
        ORR     R2, R2, R3, LSL #8
        ADD     R3, R2, #HdrSize
        CMP     R3, R1
        BNE     s_check_no
        LDRB    R3, [R0, #HdrType]
        CMP     R3, #MsgResult  ; its length depends on the tile
        BEQ     s_check_result
        CMP     R3, #MsgStatus
        BHI     s_check_no
        ADR     R1, s_lengths
        LDRB    R1, [R1, R3]
        CMP     R1, R2
        BNE     s_check_no
        MOV     R0, R3
        LDMFD   R13!, {R1-R3, PC}
s_check_result
        CMP     R2, #LenResultHead
        BLT     s_check_no
        LDRB    R1, [R0, #HdrSize + 8]
        LDRB    R3, [R0, #HdrSize + 9]
        MUL     R1, R3, R1
        ADD     R1, R1, #LenResultHead
        CMP     R1, R2
        MOVEQ   R0, #MsgResult
        LDMEQFD R13!, {R1-R3, PC}
s_check_no
        MOV     R0, #0
        LDMFD   R13!, {R1-R3, PC}

; Each type's payload length (255: not one)
s_lengths
        EQUB    255, LenHello, LenWelcome, LenReady, LenAssign, 255, LenAck, 255
        EQUB    LenComplete, 255, 255, LenDiscover, 255, LenStart, 255, 255
        EQUB    LenStop, LenStatus
        ALIGN

; Fill in a header at R3 and send it: R0 type, R1 payload length (the
; payload's at R3 + 14), R2 station, R4 port, R5 runId, R6 messageId,
; R7 our station, R8 how many tries (5cs apart). Returns Econet's status
; in R0.
s_send
        STMFD   R13!, {R1-R9, R14}
        MOV     R9, R8
        MOV     R8, #'M'
        STRB    R8, [R3, #HdrMagic]
        MOV     R8, #'A'
        STRB    R8, [R3, #HdrMagic + 1]
        MOV     R8, #Version
        STRB    R8, [R3, #HdrVersion]
        STRB    R0, [R3, #HdrType]
        MOV     R8, R1
        MOV     R0, R5
        ADD     R1, R3, #HdrRunId
        BL      s_put32
        MOV     R0, R6
        BL      s_put16
        STRB    R7, [R1], #1
        MOV     R0, #0
        STRB    R0, [R1], #1    ; flags
        MOV     R0, R8
        BL      s_put16
        MOV     R0, #Control
        MOV     R1, R4          ; port
        MOV     R4, R3          ; buffer
        MOV     R3, #0          ; net
        ADD     R5, R8, #HdrSize
        MOV     R6, R9          ; tries
        MOV     R7, #5          ; centiseconds apart
        SWI     XEconet_DoTransmit
        MOVVS   R0, #255
        LDMFD   R13!, {R1-R9, PC}

; Little-endian fields. R1 points at the field and moves past it; the
; value's in R0. The other registers are kept.
s_get16
        STMFD   R13!, {R3, R14}
        LDRB    R0, [R1], #1
        LDRB    R3, [R1], #1
        ORR     R0, R0, R3, LSL #8
        LDMFD   R13!, {R3, PC}
s_get32
        STMFD   R13!, {R3, R14}
        LDRB    R0, [R1], #1
        LDRB    R3, [R1], #1
        ORR     R0, R0, R3, LSL #8
        LDRB    R3, [R1], #1
        ORR     R0, R0, R3, LSL #16
        LDRB    R3, [R1], #1
        ORR     R0, R0, R3, LSL #24
        LDMFD   R13!, {R3, PC}
s_put16
        STMFD   R13!, {R0, R14}
        STRB    R0, [R1], #1
        MOV     R0, R0, LSR #8
        STRB    R0, [R1], #1
        LDMFD   R13!, {R0, PC}
s_put32
        STMFD   R13!, {R0, R14}
        STRB    R0, [R1], #1
        MOV     R0, R0, LSR #8
        STRB    R0, [R1], #1
        MOV     R0, R0, LSR #8
        STRB    R0, [R1], #1
        MOV     R0, R0, LSR #8
        STRB    R0, [R1], #1
        LDMFD   R13!, {R0, PC}
