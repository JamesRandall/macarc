; The worker: computes the tiles its coordinator assigns and sends back
; the counts, drawing each tile on its own screen as it goes. A worker's
; network boot runs it (its !ArmBoot: Run Net:$.LIBRARY.Worker), and it
; waits there for a coordinator: Mandel finds it with DISCOVER and gives
; it one with START. Escape ends it.
;
; It's a utility (type &FFC): RISC OS loads it into the RMA and runs it
; there, so it's position independent. It claims its workspace from the
; RMA too; R12 points at it throughout.

        ORG     0
        INCLUDE "common.s"

worker_start
        MOV     R10, R13        ; the caller's stack,
        MOV     R11, R14        ; and where to go back to
        MOV     R0, #6
        MOV     R3, #W_Size
        SWI     XOS_Module
        MOVVS   PC, R11         ; no room: the error goes back
        MOV     R12, R2
        ADD     R13, R12, #W_Size
        STR     R10, [R12, #W_CallerStack]
        STR     R11, [R12, #W_Return]
        B       w_main

; The workspace (offsets an ADD can reach in one, where they're added)
W_Tx2           * 0             ; everything but RESULT (32 bytes)
W_Rx            * 32            ; receive buffer
W_Tx            * 576           ; RESULT
W_Bands         * 1152          ; colour of each count (256 bytes)
W_Param         * 1408          ; compute's parameters (48 bytes)
W_Num           * 1472          ; number buffer (16 bytes)
W_Screen        * 1488
W_Handle        * 1492
W_RunId         * 1496
W_MessageId     * 1500
W_Station       * 1504
W_Coordinator   * 1508          ; 0: none yet
W_State         * 1512
W_Deadline      * 1516
W_Done          * 1520
W_TileId        * 1524
W_Epoch         * 1528
W_TileX         * 1532
W_TileY         * 1536
W_TileW         * 1540
W_TileH         * 1544
W_Max           * 1548
W_RxLength      * 1552
W_RxFrom        * 1556
W_CallerStack   * 1560
W_Return        * 1564
W_Size          * 2048          ; the stack's below the top

; States
S_Waiting       * 0             ; no coordinator: waiting for START
S_Hello         * 1             ; registering: HELLO every second
S_Ready         * 2             ; waiting for ASSIGN: READY every 2s
S_Compute       * 3
S_Result        * 4             ; waiting for the ACK: RESULT every 2s
S_Complete      * 5             ; the picture's done: HELLO every 3s

w_main
        SWI     XEconet_ReadLocalStationAndNet
        MOVVS   R0, #0
        STR     R0, [R12, #W_Station]
        MOV     R0, #0
        STR     R0, [R12, #W_Coordinator]
        STR     R0, [R12, #W_RunId]
        STR     R0, [R12, #W_MessageId]
        STR     R0, [R12, #W_Done]
        STR     R0, [R12, #W_Handle]
        STR     R0, [R12, #W_State]
        MOV     R0, #229        ; Escape is a key
        MOV     R1, #1
        MOV     R2, #0
        SWI     XOS_Byte
        ADD     R0, R12, #W_Bands
        BL      s_make_bands
        ADD     R1, R12, #W_Screen
        BL      s_screen
        BL      w_title
        BL      w_show_state
        BL      w_listen

w_loop
        MOV     R0, #129        ; a key? (Escape stops)
        MOV     R1, #0
        MOV     R2, #0
        SWI     XOS_Byte
        CMP     R2, #0
        CMPEQ   R1, #27
        BEQ     w_quit
        BL      w_poll
        LDR     R1, [R12, #W_State]
        CMP     R1, #S_Compute
        BEQ     w_work
        CMP     R1, #S_Waiting
        BEQ     w_loop
        SWI     XOS_ReadMonotonicTime
        LDR     R2, [R12, #W_Deadline]
        SUBS    R2, R0, R2
        BMI     w_loop
        LDR     R1, [R12, #W_State]
        CMP     R1, #S_Hello
        BEQ     w_resend_hello
        CMP     R1, #S_Complete
        BEQ     w_resend_complete
        CMP     R1, #S_Ready
        BEQ     w_resend_ready
        ; S_Result: send it again
        ADD     R2, R0, #ResultEvery
        STR     R2, [R12, #W_Deadline]
        BL      w_send_result
        B       w_loop
w_resend_hello
        ADD     R2, R0, #HelloEvery
        STR     R2, [R12, #W_Deadline]
        BL      w_send_hello
        B       w_loop
w_resend_complete
        ADD     R2, R0, #CompleteEvery
        STR     R2, [R12, #W_Deadline]
        BL      w_send_hello
        B       w_loop
w_resend_ready
        ADD     R2, R0, #ReadyEvery
        STR     R2, [R12, #W_Deadline]
        BL      w_send_ready
        B       w_loop

; Compute the tile, show it, send it
w_work
        BL      w_show_state
        ADD     R0, R12, #W_Param
        ADD     R1, R12, #W_Tx
        ADD     R1, R1, #HdrSize + LenResultHead
        STR     R1, [R0, #P_Out]
        LDR     R1, [R12, #W_TileW]
        STR     R1, [R0, #P_Width]
        LDR     R1, [R12, #W_TileH]
        STR     R1, [R0, #P_Height]
        LDR     R1, [R12, #W_Max]
        STR     R1, [R0, #P_Max]
        BL      s_compute
        ADD     R0, R12, #W_Tx
        ADD     R0, R0, #HdrSize + LenResultHead
        LDR     R1, [R12, #W_TileX]
        LDR     R2, [R12, #W_TileY]
        LDR     R3, [R12, #W_TileW]
        LDR     R4, [R12, #W_TileH]
        LDR     R5, [R12, #W_Max]
        LDR     R6, [R12, #W_Screen]
        ADD     R7, R12, #W_Bands
        BL      s_draw
        ; The RESULT's payload, before the counts
        ADD     R1, R12, #W_Tx
        ADD     R1, R1, #HdrSize
        LDR     R0, [R12, #W_TileId]
        BL      s_put16
        LDR     R0, [R12, #W_Epoch]
        BL      s_put16
        LDR     R0, [R12, #W_TileX]
        BL      s_put16
        LDR     R0, [R12, #W_TileY]
        BL      s_put16
        LDR     R0, [R12, #W_TileW]
        STRB    R0, [R1], #1
        LDR     R0, [R12, #W_TileH]
        STRB    R0, [R1], #1
        MOV     R0, #1          ; raw counts
        STRB    R0, [R1], #1
        MOV     R0, #S_Result
        STR     R0, [R12, #W_State]
        SWI     XOS_ReadMonotonicTime
        ADD     R0, R0, #ResultEvery
        STR     R0, [R12, #W_Deadline]
        BL      w_send_result
        BL      w_show_state
        B       w_loop

; Escape: close up, and go back to whoever ran it
w_quit
        LDR     R0, [R12, #W_Handle]
        CMP     R0, #0
        SWINE   XEconet_AbandonReceive
        MOV     R0, #229
        MOV     R1, #0
        MOV     R2, #0
        SWI     XOS_Byte
        MOV     R0, #23         ; the cursor back
        SWI     XOS_WriteC
        MOV     R0, #1
        SWI     XOS_WriteC
        MOV     R0, #1
        SWI     XOS_WriteC
        MOV     R1, #7
w_quit_cursor
        MOV     R0, #0
        SWI     XOS_WriteC
        SUBS    R1, R1, #1
        BNE     w_quit_cursor
        LDR     R10, [R12, #W_CallerStack]
        LDR     R11, [R12, #W_Return]
        MOV     R0, #7
        MOV     R2, R12
        SWI     XOS_Module
        MOV     R13, R10
        CMP     R0, #0          ; V clear: no error
        MOV     PC, R11

; Open the receive block
w_listen
        STMFD   R13!, {R0-R4, R14}
        MOV     R0, #PortWorker
        MOV     R1, #0          ; any station
        MOV     R2, #0
        ADD     R3, R12, #W_Rx
        MOV     R4, #RxSize
        SWI     XEconet_CreateReceive
        MOVVS   R0, #0
        STR     R0, [R12, #W_Handle]
        LDMFD   R13!, {R0-R4, PC}

; Anything received? Read it, free the block, listen again, and handle it.
w_poll
        STMFD   R13!, {R14}
        LDR     R0, [R12, #W_Handle]
        CMP     R0, #0
        BEQ     w_poll_relisten
        SWI     XEconet_ExamineReceive
        BVS     w_poll_done
        CMP     R0, #Received
        BNE     w_poll_done
        LDR     R0, [R12, #W_Handle]
        SWI     XEconet_ReadReceive
        STR     R3, [R12, #W_RxFrom]
        STR     R6, [R12, #W_RxLength]
        LDR     R0, [R12, #W_Handle]
        SWI     XEconet_AbandonReceive
        ADD     R0, R12, #W_Rx
        LDR     R1, [R12, #W_RxLength]
        BL      s_check
        CMP     R0, #0
        BLNE    w_handle
w_poll_relisten
        BL      w_listen
w_poll_done
        LDMFD   R13!, {PC}

; Handle a message of type R0 (the receive block's closed: w_poll reopens it)
w_handle
        STMFD   R13!, {R14}
        LDR     R2, [R12, #W_RxFrom]
        CMP     R0, #MsgDiscover
        BEQ     w_on_discover
        CMP     R0, #MsgStart
        BEQ     w_on_start
        CMP     R0, #MsgStop
        BEQ     w_on_stop
        LDR     R1, [R12, #W_Coordinator]
        CMP     R1, R2          ; the rest only from the coordinator
        LDMNEFD R13!, {PC}
        CMP     R0, #MsgWelcome
        BEQ     w_on_welcome
        CMP     R0, #MsgAssign
        BEQ     w_on_assign
        CMP     R0, #MsgAck
        BEQ     w_on_ack
        CMP     R0, #MsgComplete
        BEQ     w_on_complete
        LDMFD   R13!, {PC}

; DISCOVER: say it's here, and whose it is
w_on_discover
        ADD     R1, R12, #W_Rx + HdrSize
        BL      s_get32
        MOV     R1, #StateRunning
        BL      w_send_status
        LDMFD   R13!, {PC}

; START: the sender's coordinator is ours now
w_on_start
        ADD     R1, R12, #W_Rx + HdrSize + 4
        LDRB    R0, [R1]
        CMP     R0, #0
        LDMEQFD R13!, {PC}
        STR     R0, [R12, #W_Coordinator]
        ADD     R1, R12, #W_Rx + HdrSize
        BL      s_get32
        MOV     R1, #StateRunning
        BL      w_send_status
        BL      w_title
        BL      w_hello_now
        LDMFD   R13!, {PC}

; STOP: say so, and go back to waiting, as at boot
w_on_stop
        ADD     R1, R12, #W_Rx + HdrSize
        BL      s_get32
        MOV     R1, #StateStopping
        BL      w_send_status
        MOV     R0, #0
        STR     R0, [R12, #W_Coordinator]
        STR     R0, [R12, #W_RunId]
        STR     R0, [R12, #W_Done]
        STR     R0, [R12, #W_State]
        LDR     R0, [R12, #W_Screen]
        BL      s_clear
        BL      w_title
        BL      w_show_state
        LDMFD   R13!, {PC}

w_on_welcome
        ADD     R1, R12, #W_Rx + HdrRunId
        BL      s_get32
        LDR     R1, [R12, #W_RunId]
        STR     R0, [R12, #W_RunId]
        CMP     R0, R1
        BEQ     w_welcome_ready
        MOV     R0, #0          ; a new run: a new picture
        STR     R0, [R12, #W_Done]
        LDR     R0, [R12, #W_Screen]
        BL      s_clear
w_welcome_ready
        BL      w_ready_now
        LDMFD   R13!, {PC}

w_on_assign
        LDR     R0, [R12, #W_State]
        CMP     R0, #S_Ready
        LDMNEFD R13!, {PC}
        ADD     R1, R12, #W_Rx + HdrRunId
        BL      s_get32
        LDR     R1, [R12, #W_RunId]
        CMP     R0, R1
        LDMNEFD R13!, {PC}
        ADD     R1, R12, #W_Rx + HdrSize
        BL      s_get16
        STR     R0, [R12, #W_TileId]
        BL      s_get16
        STR     R0, [R12, #W_Epoch]
        BL      s_get16
        STR     R0, [R12, #W_TileX]
        BL      s_get16
        STR     R0, [R12, #W_TileY]
        LDRB    R0, [R1], #1
        STR     R0, [R12, #W_TileW]
        LDRB    R0, [R1], #1
        STR     R0, [R12, #W_TileH]
        ADD     R2, R12, #W_Param
        BL      s_get32
        STR     R0, [R2, #P_Real]
        BL      s_get32
        STR     R0, [R2, #P_Imag]
        BL      s_get32
        STR     R0, [R2, #P_StepReal]
        BL      s_get32
        STR     R0, [R2, #P_StepImag]
        LDRB    R0, [R1], #1
        STR     R0, [R12, #W_Max]
        ; A tile this worker can draw: 8-pixel columns, 512 counts at
        ; most, inside the picture, and something to count to
        CMP     R0, #0
        LDMEQFD R13!, {PC}
        LDR     R0, [R12, #W_TileW]
        LDR     R3, [R12, #W_TileH]
        MUL     R4, R0, R3
        CMP     R4, #TileSize
        LDMHIFD R13!, {PC}
        CMP     R4, #0
        LDMEQFD R13!, {PC}
        TST     R0, #7
        LDMNEFD R13!, {PC}
        LDR     R4, [R12, #W_TileX]
        TST     R4, #7
        LDMNEFD R13!, {PC}
        ADD     R4, R4, R0
        CMP     R4, #ImageWidth
        LDMHIFD R13!, {PC}
        LDR     R4, [R12, #W_TileY]
        ADD     R4, R4, R3
        CMP     R4, #ImageHeight
        LDMHIFD R13!, {PC}
        MOV     R0, #S_Compute
        STR     R0, [R12, #W_State]
        LDMFD   R13!, {PC}

w_on_ack
        LDR     R0, [R12, #W_State]
        CMP     R0, #S_Result
        LDMNEFD R13!, {PC}
        ADD     R1, R12, #W_Rx + HdrSize
        BL      s_get16
        LDR     R3, [R12, #W_TileId]
        CMP     R0, R3
        LDMNEFD R13!, {PC}
        BL      s_get16
        LDR     R3, [R12, #W_Epoch]
        CMP     R0, R3
        LDMNEFD R13!, {PC}
        LDRB    R0, [R1]
        CMP     R0, #AckAccepted
        LDREQ   R0, [R12, #W_Done]
        ADDEQ   R0, R0, #1
        STREQ   R0, [R12, #W_Done]
        BL      w_ready_now
        LDMFD   R13!, {PC}

w_on_complete
        LDR     R0, [R12, #W_State]
        CMP     R0, #S_Result   ; its ACK was lost: the RESULT goes again
        LDMEQFD R13!, {PC}
        MOV     R0, #S_Complete
        STR     R0, [R12, #W_State]
        BL      w_show_state
        SWI     XOS_ReadMonotonicTime
        ADD     R0, R0, #CompleteEvery
        STR     R0, [R12, #W_Deadline]
        LDMFD   R13!, {PC}

; HELLO now, and every second until WELCOME
w_hello_now
        STMFD   R13!, {R0, R14}
        MOV     R0, #S_Hello
        STR     R0, [R12, #W_State]
        SWI     XOS_ReadMonotonicTime
        STR     R0, [R12, #W_Deadline]
        BL      w_show_state
        LDMFD   R13!, {R0, PC}

; READY now, and every 2s until ASSIGN
w_ready_now
        STMFD   R13!, {R0, R14}
        MOV     R0, #S_Ready
        STR     R0, [R12, #W_State]
        BL      w_show_state
        BL      w_send_ready
        SWI     XOS_ReadMonotonicTime
        ADD     R0, R0, #ReadyEvery
        STR     R0, [R12, #W_Deadline]
        LDMFD   R13!, {R0, PC}

; Messages to the coordinator
w_send_hello
        STMFD   R13!, {R0-R3, R14}
        ADD     R1, R12, #W_Tx2 + HdrSize
        MOV     R0, #1          ; role: worker
        STRB    R0, [R1], #1
        MOV     R0, #0          ; reserved
        STRB    R0, [R1], #1
        MOV     R0, #1          ; numeric formats: bit 0, 4.28
        STRB    R0, [R1], #1
        MOV     R0, #Version
        STRB    R0, [R1], #1
        MOV     R0, #MsgHello
        MOV     R1, #LenHello
        LDR     R2, [R12, #W_Coordinator]
        ADD     R3, R12, #W_Tx2
        BL      w_send
        LDMFD   R13!, {R0-R3, PC}

w_send_ready
        STMFD   R13!, {R0-R3, R14}
        LDR     R0, [R12, #W_Station]
        STRB    R0, [R12, #W_Tx2 + HdrSize]
        MOV     R0, #MsgReady
        MOV     R1, #LenReady
        LDR     R2, [R12, #W_Coordinator]
        ADD     R3, R12, #W_Tx2
        BL      w_send
        LDMFD   R13!, {R0-R3, PC}

w_send_result
        STMFD   R13!, {R0-R3, R14}
        LDR     R0, [R12, #W_TileW]
        LDR     R1, [R12, #W_TileH]
        MUL     R1, R0, R1
        ADD     R1, R1, #LenResultHead
        MOV     R0, #MsgResult
        LDR     R2, [R12, #W_Coordinator]
        ADD     R3, R12, #W_Tx
        BL      w_send
        LDMFD   R13!, {R0-R3, PC}

; STATUS: R0 nonce, R1 state, R2 to whom
w_send_status
        STMFD   R13!, {R0-R3, R14}
        MOV     R3, R1
        ADD     R1, R12, #W_Tx2 + HdrSize
        BL      s_put32
        STRB    R3, [R1], #1
        MOV     R0, #Version
        STRB    R0, [R1], #1
        LDR     R0, [R12, #W_Coordinator]
        STRB    R0, [R1], #1
        MOV     R0, #MsgStatus
        MOV     R1, #LenStatus
        ADD     R3, R12, #W_Tx2
        BL      w_send
        LDMFD   R13!, {R0-R3, PC}

; Send to the coordinator's port: R0 type, R1 payload length, R2 station,
; R3 buffer (payload at +14)
w_send
        STMFD   R13!, {R0-R8, R14}
        MOV     R8, #5          ; tries
        MOV     R4, #PortCoordinator
        LDR     R5, [R12, #W_RunId]
        LDR     R6, [R12, #W_MessageId]
        ADD     R6, R6, #1
        STR     R6, [R12, #W_MessageId]
        LDR     R7, [R12, #W_Station]
        BL      s_send
        LDMFD   R13!, {R0-R8, PC}

; The title line (79 characters at most, so it never wraps)
w_title
        STMFD   R13!, {R0-R2, R14}
        MOV     R0, #0
        MOV     R1, #0
        BL      s_tab
        ADR     R0, w_title_text
        SWI     XOS_Write0
        LDR     R0, [R12, #W_Station]
        ADD     R1, R12, #W_Num
        BL      s_number
        LDR     R0, [R12, #W_Coordinator]
        CMP     R0, #0
        ADREQ   R0, w_title_none
        SWIEQ   XOS_Write0
        LDMEQFD R13!, {R0-R2, PC}
        ADR     R0, w_title_for
        SWI     XOS_Write0
        LDR     R0, [R12, #W_Coordinator]
        ADD     R1, R12, #W_Num
        BL      s_number
        ADR     R0, w_title_end
        SWI     XOS_Write0
        LDMFD   R13!, {R0-R2, PC}
w_title_text
        EQUS    "Distributed Mandelbrot: worker on station "
        EQUB    0
w_title_none
        EQUS    ", waiting for a coordinator      "
        EQUB    0
w_title_for
        EQUS    ", for station "
        EQUB    0
w_title_end
        EQUS    "                 "
        EQUB    0
        ALIGN

; The state line
w_show_state
        STMFD   R13!, {R0-R2, R14}
        MOV     R0, #0
        MOV     R1, #1
        BL      s_tab
        ADR     R0, w_state_text
        SWI     XOS_Write0
        LDR     R0, [R12, #W_Done]
        ADD     R1, R12, #W_Num
        BL      s_number
        ADR     R0, w_state_text2
        SWI     XOS_Write0
        LDR     R1, [R12, #W_State]
        ADR     R0, w_states
        ADD     R0, R0, R1, LSL #4
        SWI     XOS_Write0
        LDMFD   R13!, {R0-R2, PC}
w_state_text
        EQUS    "Tiles done: "
        EQUB    0
w_state_text2
        EQUS    "   "
        EQUB    0
        ALIGN
w_states
        EQUS    "Waiting        "
        EQUB    0
        EQUS    "Registering    "
        EQUB    0
        EQUS    "Ready          "
        EQUB    0
        EQUS    "Computing      "
        EQUB    0
        EQUS    "Sending        "
        EQUB    0
        EQUS    "Picture done   "
        EQUB    0

        INCLUDE "shared.s"
worker_end
