; Hello, ARM: prints a greeting, then counts down from 5.
;
; Press F5 in VS Code (with the MacArch extension) to assemble and run it
; on MacArch, or ask an agent to use the assemble tool. Set breakpoints by
; clicking in the margin.

        ORG     &8000

.start
        SWI     OS_GetEnv           ; R1 = the top of application memory
        MOV     R13, R1             ; the stack grows down from there
        ADR     R0, greeting
        SWI     "OS_Write0"
        SWI     OS_NewLine
        MOV     R4, #5              ; count down from 5
.loop
        MOV     R0, R4
        BL      print_digit
        SUBS    R4, R4, #1
        BNE     loop
        SWI     OS_NewLine
        SWI     OS_Exit

; Prints R0 (0-9) as a digit and a space.
.print_digit
        STMFD   R13!, {R0, R14}
        ADD     R0, R0, #'0'
        SWI     OS_WriteC
        SWI     OS_WriteI+' '
        LDMFD   R13!, {R0, PC}

.greeting
        EQUS    "Hello from the Archimedes!"
        EQUB    0
        ALIGN
