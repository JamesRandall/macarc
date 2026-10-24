; Mandel, the coordinator: finds the workers on the network (DISCOVER,
; then START for any that aren't its own), registers them, hands out the
; 300 tiles, takes back their counts and draws them. A tile out for more
; than 20s goes back in the queue; a RESULT from an older assignment is
; refused. When all 300 are in it tells the workers, and cycles the
; colours until a key's pressed. Escape gives up part way.
;
; "Mandel Stop" stops the workers instead: STOP to each that's running.
;
; An application (type &FF8) at &8000. Its workspace follows the code;
; R12 points at it throughout.

        ORG     &8000
        INCLUDE "common.s"

; The workspace
M_Tx            * 0             ; transmit buffer (64 bytes)
M_Num           * 64            ; number buffer (16 bytes)
M_Screen        * 80
M_Handles       * 84            ; the receive blocks (4)
M_Station       * 100
M_RunId         * 104
M_MessageId     * 108
M_Done          * 112           ; tiles accepted
M_Workers       * 116           ; workers registered
M_Complete      * 120
M_Start         * 124           ; when the run began, and ended (cs)
M_End           * 128
M_Probe         * 132           ; the last station probed
M_ProbeTime     * 136           ; when to probe next
M_Redraw        * 140           ; when to redraw the status line
M_RxFrom        * 144
M_RxLength      * 148
M_RxBuf         * 152
M_Cycle         * 156           ; the colours' turn
M_StopMode      * 160
M_Stopped       * 164
M_Unresponsive  * 168           ; the last unresponsive worker probed
M_Frames        * 172
M_Bands         * 256           ; colour of each count (256 bytes)
M_Rx            * 512           ; receive buffers
Receivers       * 4
M_Tiles         * 4096          ; per tile (T_*)
M_WorkerTable   * 12288         ; per station (WK_*)
M_Size          * 16384

; A tile
T_State         * 0             ; pending, out, done
T_Worker        * 4             ; the station it was last given to
T_Epoch         * 8             ; its latest assignment
T_Time          * 12            ; when it was given out
TilePending     * 0
TileOut         * 1
TileDone        * 2

; A station
WK_Flags        * 0             ; Known, Unresponsive
WK_Tile         * 4             ; the tile it has, or -1
WK_Tiles        * 8             ; tiles accepted from it
WK_Heard        * 12            ; when it last sent anything
Known           * 1
Unresponsive    * 2

mandel_start
        SWI     XOS_GetEnv      ; R0 the command line, R1 the top of memory
        MOV     R13, R1
        MOV     R9, R0
        ADRL    R12, mandel_end
        MOV     R0, #0
        MOV     R1, #M_Size
        MOV     R2, R12
m_zero
        STR     R0, [R2], #4
        SUBS    R1, R1, #4
        BGT     m_zero
        ; "Mandel Stop"? The word after the first.
m_skip_spaces
        LDRB    R0, [R9]
        CMP     R0, #' '
        ADDEQ   R9, R9, #1
        BEQ     m_skip_spaces
m_skip_word
        LDRB    R0, [R9]
        CMP     R0, #' '
        ADDHI   R9, R9, #1
        BHI     m_skip_word
m_skip_spaces2
        LDRB    R0, [R9]
        CMP     R0, #' '
        ADDEQ   R9, R9, #1
        BEQ     m_skip_spaces2
        ORR     R0, R0, #&20    ; lower case
        CMP     R0, #'s'
        MOVEQ   R0, #1
        MOVNE   R0, #0
        STR     R0, [R12, #M_StopMode]
        SWI     XEconet_ReadLocalStationAndNet
        BVS     m_no_econet
        STR     R0, [R12, #M_Station]
        SWI     XOS_ReadMonotonicTime
        CMP     R0, #0
        MOVEQ   R0, #1
        STR     R0, [R12, #M_RunId]
        LDR     R0, [R12, #M_StopMode]
        CMP     R0, #0
        BNE     m_stop_workers

        ; Draw
        ADD     R0, R12, #M_Bands
        BL      s_make_bands
        MOV     R0, #229        ; Escape is a key
        MOV     R1, #1
        MOV     R2, #0
        SWI     XOS_Byte
        ADD     R1, R12, #M_Screen
        BL      s_screen
        BL      m_title
        BL      m_listen
        SWI     XOS_ReadMonotonicTime
        STR     R0, [R12, #M_Start]
        STR     R0, [R12, #M_Redraw]
        ADD     R0, R0, #ProbeEvery
        STR     R0, [R12, #M_ProbeTime]
        MOV     R0, #LastProbe
        STR     R0, [R12, #M_Probe]
        BL      m_status
        BL      m_sweep

m_loop
        MOV     R0, #129        ; a key?
        MOV     R1, #0
        MOV     R2, #0
        SWI     XOS_Byte
        CMP     R2, #0
        BNE     m_no_key
        LDR     R0, [R12, #M_Complete]
        CMP     R0, #0
        BNE     m_finish        ; any key, once it's done
        CMP     R1, #27
        BEQ     m_finish        ; Escape before
m_no_key
        BL      m_poll
        LDR     R0, [R12, #M_Complete]
        CMP     R0, #0
        BNE     m_cycle
        BL      m_timeouts
        BL      m_probe
        SWI     XOS_ReadMonotonicTime
        LDR     R1, [R12, #M_Redraw]
        SUBS    R1, R0, R1
        BLPL    m_status
        B       m_loop

; Done: the colours turn every fourth frame
m_cycle
        MOV     R0, #19         ; wait for the vertical sync
        SWI     XOS_Byte
        LDR     R0, [R12, #M_Frames]
        ADD     R0, R0, #1
        STR     R0, [R12, #M_Frames]
        TST     R0, #3
        BNE     m_loop
        LDR     R0, [R12, #M_Cycle]
        ADD     R0, R0, #1
        CMP     R0, #Bands
        MOVEQ   R0, #0
        STR     R0, [R12, #M_Cycle]
        BL      s_palette
        B       m_loop

; A key: close up, and say what happened
m_finish
        BL      m_close
        ADR     R0, m_finish_vdu
        MOV     R1, #m_finish_text - m_finish_vdu
        SWI     XOS_WriteN
        ADR     R0, m_finish_text
        SWI     XOS_Write0
        BL      m_summary
        B       m_exit
m_finish_vdu
        EQUB    20, 12, 23, 1, 1, 0, 0, 0, 0, 0, 0, 0   ; the colours, a clear screen, the cursor
m_finish_text
        EQUS    "Distributed Mandelbrot"
        EQUB    13, 10, 0
        ALIGN

m_no_econet
        ADR     R0, m_no_econet_text
        SWI     XOS_Write0
        B       m_exit
m_no_econet_text
        EQUS    "Mandel needs Econet: this machine has no Econet module."
        EQUB    13, 10, 0
        ALIGN

m_exit
        MOV     R0, #0
        MOV     R1, #0
        MOV     R2, #0
        SWI     XOS_Exit

; The receive blocks closed, and Escape back to normal
m_close
        STMFD   R13!, {R0-R4, R14}
        MOV     R4, #0
m_close_one
        ADD     R1, R12, #M_Handles
        LDR     R0, [R1, R4, LSL #2]
        CMP     R0, #0
        SWINE   XEconet_AbandonReceive
        MOV     R0, #0
        STR     R0, [R1, R4, LSL #2]
        ADD     R4, R4, #1
        CMP     R4, #Receivers
        BLT     m_close_one
        MOV     R0, #229
        MOV     R1, #0
        MOV     R2, #0
        SWI     XOS_Byte
        LDMFD   R13!, {R0-R4, PC}

; "300 of 300 tiles in 41.5s from 3 workers", then each worker's tiles
m_summary
        STMFD   R13!, {R0-R5, R14}
        LDR     R0, [R12, #M_Done]
        BL      m_print_number
        ADR     R0, m_summary_of
        SWI     XOS_Write0
        LDR     R0, [R12, #M_Complete]
        CMP     R0, #0
        SWIEQ   XOS_ReadMonotonicTime
        LDRNE   R0, [R12, #M_End]
        LDR     R1, [R12, #M_Start]
        SUB     R0, R0, R1
        BL      m_print_seconds
        ADR     R0, m_summary_from
        SWI     XOS_Write0
        LDR     R0, [R12, #M_Workers]
        BL      m_print_number
        ADR     R0, m_summary_workers
        SWI     XOS_Write0
        MOV     R4, #1
m_summary_one
        ADD     R5, R12, #M_WorkerTable
        ADD     R5, R5, R4, LSL #4
        LDR     R0, [R5, #WK_Flags]
        TST     R0, #Known
        BEQ     m_summary_next
        ADR     R0, m_summary_station
        SWI     XOS_Write0
        MOV     R0, R4
        BL      m_print_number
        ADR     R0, m_summary_colon
        SWI     XOS_Write0
        LDR     R0, [R5, #WK_Tiles]
        BL      m_print_number
        ADR     R0, m_summary_tiles
        SWI     XOS_Write0
m_summary_next
        ADD     R4, R4, #1
        CMP     R4, #255
        BLT     m_summary_one
        LDMFD   R13!, {R0-R5, PC}
m_summary_of
        EQUS    " of 300 tiles in "
        EQUB    0
m_summary_from
        EQUS    " from "
        EQUB    0
m_summary_workers
        EQUS    " workers"
        EQUB    13, 10, 0
m_summary_station
        EQUS    "  Station "
        EQUB    0
m_summary_colon
        EQUS    ": "
        EQUB    0
m_summary_tiles
        EQUS    " tiles"
        EQUB    13, 10, 0
        ALIGN

; ---------------------------------------------------------------------
; Stopping the workers ("Mandel Stop")

m_stop_workers
        ADR     R0, m_stopping_text
        SWI     XOS_Write0
        BL      m_listen
        BL      m_sweep
        SWI     XOS_ReadMonotonicTime
        ADD     R4, R0, #300    ; answers for 3s more
m_stop_wait
        BL      m_poll
        SWI     XOS_ReadMonotonicTime
        SUBS    R0, R0, R4
        BMI     m_stop_wait
        BL      m_close
        LDR     R0, [R12, #M_Stopped]
        BL      m_print_number
        ADR     R0, m_stopped_text
        SWI     XOS_Write0
        B       m_exit
m_stopping_text
        EQUS    "Stopping the Mandelbrot workers..."
        EQUB    13, 10, 0
m_stopped_text
        EQUS    " stopped."
        EQUB    13, 10, 0
        ALIGN

; ---------------------------------------------------------------------
; Receiving

; Open any receive block that isn't
m_listen
        STMFD   R13!, {R0-R6, R14}
        MOV     R6, #0
m_listen_one
        ADD     R5, R12, #M_Handles
        LDR     R0, [R5, R6, LSL #2]
        CMP     R0, #0
        BNE     m_listen_next
        MOV     R0, #PortCoordinator
        MOV     R1, #0          ; any station
        MOV     R2, #0
        BL      m_rx_buffer
        MOV     R4, #RxSize
        SWI     XEconet_CreateReceive
        MOVVS   R0, #0
        STR     R0, [R5, R6, LSL #2]
m_listen_next
        ADD     R6, R6, #1
        CMP     R6, #Receivers
        BLT     m_listen_one
        LDMFD   R13!, {R0-R6, PC}

; R3 = receive buffer R6
m_rx_buffer
        STMFD   R13!, {R0, R14}
        MOV     R0, #RxSize
        MUL     R3, R0, R6
        ADD     R3, R3, R12
        ADD     R3, R3, #M_Rx
        LDMFD   R13!, {R0, PC}

; Handle whatever's been received, and listen again
m_poll
        STMFD   R13!, {R0-R8, R14}
        MOV     R7, #0          ; the block
        ADD     R8, R12, #M_Handles
m_poll_one
        LDR     R0, [R8, R7, LSL #2]
        CMP     R0, #0
        BEQ     m_poll_next
        SWI     XEconet_ExamineReceive
        BVS     m_poll_next
        CMP     R0, #Received
        BNE     m_poll_next
        LDR     R0, [R8, R7, LSL #2]
        SWI     XEconet_ReadReceive
        STR     R3, [R12, #M_RxFrom]
        STR     R6, [R12, #M_RxLength]
        LDR     R0, [R8, R7, LSL #2]
        SWI     XEconet_AbandonReceive
        MOV     R0, #0
        STR     R0, [R8, R7, LSL #2]
        MOV     R6, R7
        BL      m_rx_buffer
        STR     R3, [R12, #M_RxBuf]
        MOV     R0, R3
        LDR     R1, [R12, #M_RxLength]
        BL      s_check
        CMP     R0, #0
        BLNE    m_handle
m_poll_next
        ADD     R7, R7, #1
        CMP     R7, #Receivers
        BLT     m_poll_one
        BL      m_listen
        LDMFD   R13!, {R0-R8, PC}

; A message of type R0 from M_RxFrom, in M_RxBuf
m_handle
        STMFD   R13!, {R0-R11, R14}
        LDR     R2, [R12, #M_RxFrom]
        BL      m_worker
        STMFD   R13!, {R0}
        SWI     XOS_ReadMonotonicTime
        STR     R0, [R5, #WK_Heard]
        LDMFD   R13!, {R0}
        CMP     R0, #MsgStatus
        BEQ     m_on_status
        LDR     R1, [R12, #M_StopMode]
        CMP     R1, #0
        BNE     m_handled
        CMP     R0, #MsgHello
        BEQ     m_on_hello
        CMP     R0, #MsgReady
        BEQ     m_on_ready
        CMP     R0, #MsgResult
        BEQ     m_on_result
m_handled
        LDMFD   R13!, {R0-R11, PC}

; STATUS: a worker answering DISCOVER, START or STOP
m_on_status
        LDR     R1, [R12, #M_RxBuf]
        ADD     R1, R1, #HdrSize + 4
        LDRB    R3, [R1], #1    ; state
        LDRB    R4, [R1, #1]    ; its coordinator
        LDR     R0, [R12, #M_StopMode]
        CMP     R0, #0
        BNE     m_status_stopping
        CMP     R3, #StateRunning
        BNE     m_handled
        LDR     R0, [R12, #M_Station]
        CMP     R4, R0
        BEQ     m_handled       ; ours already: its HELLO's coming
        BL      m_send_start
        B       m_handled
m_status_stopping
        CMP     R3, #StateRunning
        BLEQ    m_send_stop
        CMP     R3, #StateStopping
        LDREQ   R0, [R12, #M_Stopped]
        ADDEQ   R0, R0, #1
        STREQ   R0, [R12, #M_Stopped]
        B       m_handled

; HELLO: register it (again) and WELCOME it, unless the run's done
m_on_hello
        BL      m_same_run
        BNE     m_welcome_it
        LDR     R0, [R12, #M_Complete]
        CMP     R0, #0
        BNE     m_complete_it
m_welcome_it
        BL      m_register
        BL      m_send_welcome
        B       m_handled
m_complete_it
        BL      m_send_complete
        B       m_handled

; READY: its tile again, or the next, or nothing
m_on_ready
        BL      m_same_run
        BNE     m_welcome_it
        LDR     R0, [R12, #M_Complete]
        CMP     R0, #0
        BNE     m_complete_it
        BL      m_worker        ; R5 its record
        LDR     R0, [R5, #WK_Flags]
        TST     R0, #Known
        BLEQ    m_register
        LDR     R0, [R5, #WK_Flags]
        BIC     R0, R0, #Unresponsive
        STR     R0, [R5, #WK_Flags]
        LDR     R0, [R5, #WK_Tile]
        CMN     R0, #1
        BEQ     m_ready_next
        BL      m_tile          ; R6 its record
        LDR     R1, [R6, #T_State]
        CMP     R1, #TileOut
        LDREQ   R1, [R6, #T_Worker]
        CMPEQ   R1, R2
        BNE     m_ready_next
        SWI     XOS_ReadMonotonicTime
        STR     R0, [R6, #T_Time]
        LDR     R0, [R5, #WK_Tile]
        BL      m_send_assign   ; the same tile, the same epoch
        B       m_handled
m_ready_next
        MVN     R0, #0
        STR     R0, [R5, #WK_Tile]
        MOV     R0, #0
m_ready_find
        BL      m_tile
        LDR     R1, [R6, #T_State]
        CMP     R1, #TilePending
        BEQ     m_ready_give
        ADD     R0, R0, #1
        CMP     R0, #Tiles
        BLT     m_ready_find
        B       m_handled       ; none left: it's idle
m_ready_give
        MOV     R1, #TileOut
        STR     R1, [R6, #T_State]
        STR     R2, [R6, #T_Worker]
        LDR     R1, [R6, #T_Epoch]
        ADD     R1, R1, #1
        BIC     R1, R1, #&FF0000
        STR     R1, [R6, #T_Epoch]
        STR     R0, [R5, #WK_Tile]
        MOV     R4, R0
        SWI     XOS_ReadMonotonicTime
        STR     R0, [R6, #T_Time]
        MOV     R0, R4
        BL      m_send_assign
        B       m_handled

; RESULT: accept it, if it's the tile's latest assignment and its own
m_on_result
        BL      m_same_run
        BNE     m_welcome_it
        LDR     R1, [R12, #M_RxBuf]
        ADD     R1, R1, #HdrSize
        BL      s_get16
        MOV     R7, R0          ; tile
        BL      s_get16
        MOV     R8, R0          ; epoch
        CMP     R7, #Tiles
        BHS     m_handled
        ; It must be the tile it says: where it is, its size, raw counts
        MOV     R0, R7
        BL      m_origin        ; R3 x, R4 y
        BL      s_get16
        CMP     R0, R3
        BNE     m_handled
        BL      s_get16
        CMP     R0, R4
        BNE     m_handled
        LDRB    R0, [R1], #1
        CMP     R0, #TileWidth
        LDREQB  R0, [R1], #1
        CMPEQ   R0, #TileHeight
        LDREQB  R0, [R1], #1
        CMPEQ   R0, #1
        BNE     m_handled
        MOV     R9, R1          ; the counts
        BL      m_worker
        LDR     R0, [R5, #WK_Flags]
        BIC     R0, R0, #Unresponsive
        STR     R0, [R5, #WK_Flags]
        MOV     R0, R7
        BL      m_tile
        LDR     R0, [R6, #T_Epoch]
        LDR     R1, [R6, #T_Worker]
        LDR     R10, [R6, #T_State]
        CMP     R0, R8
        CMPEQ   R1, R2
        MOVEQ   R11, #AckAccepted       ; the latest, and its
        MOVNE   R11, #AckStale
        CMP     R10, #TileDone
        BEQ     m_result_done
        CMP     R11, #AckAccepted
        BNE     m_result_ack
        ; Accepted: draw it
        MOV     R0, #TileDone
        STR     R0, [R6, #T_State]
        LDR     R0, [R12, #M_Done]
        ADD     R0, R0, #1
        STR     R0, [R12, #M_Done]
        LDR     R0, [R5, #WK_Tiles]
        ADD     R0, R0, #1
        STR     R0, [R5, #WK_Tiles]
        LDR     R0, [R5, #WK_Tile]
        CMP     R0, R7
        MVNEQ   R0, #0
        STREQ   R0, [R5, #WK_Tile]
        STMFD   R13!, {R2}
        MOV     R0, R9
        MOV     R1, R3
        MOV     R2, R4
        MOV     R3, #TileWidth
        MOV     R4, #TileHeight
        MOV     R5, #MaxIterations
        LDR     R6, [R12, #M_Screen]
        ADD     R7, R12, #M_Bands
        BL      s_draw
        LDMFD   R13!, {R2}
        LDR     R1, [R12, #M_RxBuf]
        ADD     R1, R1, #HdrSize
        BL      s_get16
        MOV     R7, R0          ; the tile again
        B       m_result_ack
m_result_done
        ; Done already: its own again (its ACK was lost), or someone else's
        CMP     R11, #AckAccepted
        MOVNE   R11, #AckDuplicate
m_result_ack
        MOV     R0, R7
        MOV     R1, R8
        MOV     R3, R11
        BL      m_send_ack
        LDR     R0, [R12, #M_Done]
        CMP     R0, #Tiles
        BLT     m_handled
        LDR     R0, [R12, #M_Complete]
        CMP     R0, #0
        BLEQ    m_completed
        B       m_handled

; All 300 in: COMPLETE to every worker it knows
m_completed
        STMFD   R13!, {R0-R5, R14}
        MOV     R0, #1
        STR     R0, [R12, #M_Complete]
        SWI     XOS_ReadMonotonicTime
        STR     R0, [R12, #M_End]
        BL      m_status
        MOV     R4, #1
m_completed_one
        ADD     R5, R12, #M_WorkerTable
        ADD     R5, R5, R4, LSL #4
        LDR     R0, [R5, #WK_Flags]
        TST     R0, #Known
        MOVNE   R2, R4
        BLNE    m_send_complete
        ADD     R4, R4, #1
        CMP     R4, #255
        BLT     m_completed_one
        LDMFD   R13!, {R0-R5, PC}

; Z set if the message is in this run
m_same_run
        STMFD   R13!, {R0-R1, R14}
        LDR     R1, [R12, #M_RxBuf]
        ADD     R1, R1, #HdrRunId
        BL      s_get32
        LDR     R1, [R12, #M_RunId]
        CMP     R0, R1
        LDMFD   R13!, {R0-R1, PC}

; R5 = station R2's record
m_worker
        ADD     R5, R12, #M_WorkerTable
        ADD     R5, R5, R2, LSL #4
        MOV     PC, R14

; R6 = tile R0's record
m_tile
        ADD     R6, R12, #M_Tiles
        ADD     R6, R6, R0, LSL #4
        MOV     PC, R14

; Tile R0's top left: R3 x, R4 y
m_origin
        STMFD   R13!, {R0, R14}
        MOV     R4, #0
m_origin_row
        CMP     R0, #TileColumns
        SUBHS   R0, R0, #TileColumns
        ADDHS   R4, R4, #1
        BHS     m_origin_row
        MOV     R3, R0, LSL #5          ; x 32
        MOV     R4, R4, LSL #4          ; x 16
        LDMFD   R13!, {R0, PC}

; Register station R2, or, if it's known, take its tile back; either
; way it's answering
m_register
        STMFD   R13!, {R0-R6, R14}
        BL      m_worker
        LDR     R0, [R5, #WK_Flags]
        TST     R0, #Known
        BNE     m_register_again
        MOV     R0, #Known
        STR     R0, [R5, #WK_Flags]
        MVN     R0, #0
        STR     R0, [R5, #WK_Tile]
        LDR     R0, [R12, #M_Workers]
        ADD     R0, R0, #1
        STR     R0, [R12, #M_Workers]
        BL      m_status
        LDMFD   R13!, {R0-R6, PC}
m_register_again
        BIC     R0, R0, #Unresponsive
        STR     R0, [R5, #WK_Flags]
        LDR     R0, [R5, #WK_Tile]
        CMN     R0, #1
        LDMEQFD R13!, {R0-R6, PC}
        BL      m_tile
        LDR     R1, [R6, #T_State]
        CMP     R1, #TileOut
        LDREQ   R1, [R6, #T_Worker]
        CMPEQ   R1, R2
        MOVEQ   R1, #TilePending
        STREQ   R1, [R6, #T_State]
        MVN     R0, #0
        STR     R0, [R5, #WK_Tile]
        LDMFD   R13!, {R0-R6, PC}

; Tiles out too long go back in the queue; their workers are unresponsive,
; as is a worker that's said nothing for 10s (they talk every 2s at least:
; one switched off between tiles holds none to time out)
m_timeouts
        STMFD   R13!, {R0-R7, R14}
        SWI     XOS_ReadMonotonicTime
        MOV     R7, R0
        MOV     R0, #0
m_timeouts_one
        BL      m_tile
        LDR     R1, [R6, #T_State]
        CMP     R1, #TileOut
        BNE     m_timeouts_next
        LDR     R1, [R6, #T_Time]
        SUB     R1, R7, R1
        CMP     R1, #TileTimeout
        BLE     m_timeouts_next
        MOV     R1, #TilePending
        STR     R1, [R6, #T_State]
        LDR     R2, [R6, #T_Worker]
        BL      m_worker
        LDR     R1, [R5, #WK_Flags]
        ORR     R1, R1, #Unresponsive
        STR     R1, [R5, #WK_Flags]
        LDR     R1, [R5, #WK_Tile]
        CMP     R1, R0
        MVNEQ   R1, #0
        STREQ   R1, [R5, #WK_Tile]
m_timeouts_next
        ADD     R0, R0, #1
        CMP     R0, #Tiles
        BLT     m_timeouts_one
        MOV     R2, #1
m_silent_one
        BL      m_worker
        LDR     R1, [R5, #WK_Flags]
        TST     R1, #Known
        BEQ     m_silent_next
        LDR     R0, [R5, #WK_Heard]
        SUB     R0, R7, R0
        CMP     R0, #SilentTimeout
        ORRGT   R1, R1, #Unresponsive
        STRGT   R1, [R5, #WK_Flags]
m_silent_next
        ADD     R2, R2, #1
        CMP     R2, #255
        BLT     m_silent_one
        LDMFD   R13!, {R0-R7, PC}

; Once a second: DISCOVER to the next unresponsive worker (it may have
; been switched off and on), and to the next station that isn't working
; for us (one that's booted since).
m_probe
        STMFD   R13!, {R0-R6, R14}
        SWI     XOS_ReadMonotonicTime
        LDR     R1, [R12, #M_ProbeTime]
        SUBS    R1, R0, R1
        LDMMIFD R13!, {R0-R6, PC}
        ADD     R0, R0, #ProbeEvery
        STR     R0, [R12, #M_ProbeTime]
        LDR     R2, [R12, #M_Unresponsive]
        MOV     R3, #255
m_probe_unresponsive
        ADD     R2, R2, #1
        CMP     R2, #255
        MOVHS   R2, #1
        BL      m_worker
        LDR     R0, [R5, #WK_Flags]
        TST     R0, #Unresponsive
        BNE     m_probe_found
        SUBS    R3, R3, #1
        BNE     m_probe_unresponsive
        B       m_probe_stranger
m_probe_found
        STR     R2, [R12, #M_Unresponsive]
        BL      m_send_discover
m_probe_stranger
        LDR     R2, [R12, #M_Probe]
        MOV     R3, #LastProbe
m_probe_next
        ADD     R2, R2, #1
        CMP     R2, #LastProbe
        MOVHI   R2, #FirstProbe
        LDR     R0, [R12, #M_Station]
        CMP     R2, R0
        BEQ     m_probe_skip
        BL      m_worker
        LDR     R0, [R5, #WK_Flags]
        CMP     R0, #Known      ; known and answering: skip it
        BNE     m_probe_send
m_probe_skip
        SUBS    R3, R3, #1
        BNE     m_probe_next
        LDMFD   R13!, {R0-R6, PC}
m_probe_send
        STR     R2, [R12, #M_Probe]
        BL      m_send_discover
        LDMFD   R13!, {R0-R6, PC}

; DISCOVER to every station that might have a worker, handling the
; answers as they come
m_sweep
        STMFD   R13!, {R0-R2, R14}
        MOV     R2, #FirstProbe
m_sweep_one
        LDR     R0, [R12, #M_Station]
        CMP     R2, R0
        BLNE    m_send_discover
        BL      m_poll
        ADD     R2, R2, #1
        CMP     R2, #LastProbe
        BLS     m_sweep_one
        LDMFD   R13!, {R0-R2, PC}

; ---------------------------------------------------------------------
; Sending: each to station R2

m_send_welcome
        STMFD   R13!, {R0-R1, R14}
        ADD     R1, R12, #M_Tx + HdrSize
        MOV     R0, #ImageWidth
        BL      s_put16
        MOV     R0, #ImageHeight
        BL      s_put16
        MOV     R0, #MaxIterations
        BL      s_put16
        MOV     R0, #TileWidth
        STRB    R0, [R1], #1
        MOV     R0, #TileHeight
        STRB    R0, [R1], #1
        MOV     R0, #MsgWelcome
        MOV     R1, #LenWelcome
        BL      m_send
        LDMFD   R13!, {R0-R1, PC}

; ASSIGN tile R0 (its epoch's in its record)
m_send_assign
        STMFD   R13!, {R0-R6, R14}
        MOV     R5, R0
        BL      m_tile
        ADD     R1, R12, #M_Tx + HdrSize
        BL      s_put16         ; tile
        LDR     R0, [R6, #T_Epoch]
        BL      s_put16
        MOV     R0, R5
        BL      m_origin
        MOV     R0, R3
        BL      s_put16         ; x
        MOV     R0, R4
        BL      s_put16         ; y
        MOV     R0, #TileWidth
        STRB    R0, [R1], #1
        MOV     R0, #TileHeight
        STRB    R0, [R1], #1
        LDR     R5, =StepReal
        MUL     R0, R3, R5
        LDR     R6, =ViewLeft
        ADD     R0, R0, R6
        BL      s_put32         ; startReal
        LDR     R6, =StepImag
        MUL     R0, R4, R6
        LDR     R3, =ViewTop
        ADD     R0, R0, R3
        BL      s_put32         ; startImag
        MOV     R0, R5
        BL      s_put32         ; stepReal
        MOV     R0, R6
        BL      s_put32         ; stepImag
        MOV     R0, #MaxIterations
        BL      s_put16         ; maxIterations, and the reserved byte
        MOV     R0, #MsgAssign
        MOV     R1, #LenAssign
        BL      m_send
        LDMFD   R13!, {R0-R6, PC}

; ACK: R0 tile, R1 epoch, R3 status
m_send_ack
        STMFD   R13!, {R0-R1, R14}
        STMFD   R13!, {R1}
        ADD     R1, R12, #M_Tx + HdrSize
        BL      s_put16
        LDMFD   R13!, {R0}
        BL      s_put16
        STRB    R3, [R1], #1
        MOV     R0, #MsgAck
        MOV     R1, #LenAck
        BL      m_send
        LDMFD   R13!, {R0-R1, PC}

m_send_complete
        STMFD   R13!, {R0-R1, R14}
        ADD     R1, R12, #M_Tx + HdrSize
        LDR     R0, [R12, #M_Done]
        BL      s_put16
        MOV     R0, #MsgComplete
        MOV     R1, #LenComplete
        BL      m_send
        LDMFD   R13!, {R0-R1, PC}

; DISCOVER (tried twice: nobody may be there)
m_send_discover
        STMFD   R13!, {R0-R1, R14}
        ADD     R1, R12, #M_Tx + HdrSize
        LDR     R0, [R12, #M_RunId]
        BL      s_put32
        MOV     R0, #MsgDiscover
        MOV     R1, #LenDiscover
        BL      m_send_once
        LDMFD   R13!, {R0-R1, PC}

m_send_start
        STMFD   R13!, {R0-R1, R14}
        ADD     R1, R12, #M_Tx + HdrSize
        LDR     R0, [R12, #M_RunId]
        BL      s_put32
        LDR     R0, [R12, #M_Station]
        STRB    R0, [R1], #1
        MOV     R0, #MsgStart
        MOV     R1, #LenStart
        BL      m_send
        LDMFD   R13!, {R0-R1, PC}

m_send_stop
        STMFD   R13!, {R0-R1, R14}
        ADD     R1, R12, #M_Tx + HdrSize
        LDR     R0, [R12, #M_RunId]
        BL      s_put32
        MOV     R0, #MsgStop
        MOV     R1, #LenStop
        BL      m_send
        LDMFD   R13!, {R0-R1, PC}

; Send to a worker's port: R0 type, R1 payload length, R2 station
m_send
        STMFD   R13!, {R0-R8, R14}
        MOV     R8, #5          ; tries
        B       m_send_tries
m_send_once
        STMFD   R13!, {R0-R8, R14}
        MOV     R8, #2
m_send_tries
        ADD     R3, R12, #M_Tx
        MOV     R4, #PortWorker
        LDR     R5, [R12, #M_RunId]
        LDR     R6, [R12, #M_MessageId]
        ADD     R6, R6, #1
        STR     R6, [R12, #M_MessageId]
        LDR     R7, [R12, #M_Station]
        BL      s_send
        CMP     R0, #0          ; not there: a worker it knows is unresponsive
        BEQ     m_sent
        BL      m_worker
        LDR     R0, [R5, #WK_Flags]
        TST     R0, #Known
        ORRNE   R0, R0, #Unresponsive
        STRNE   R0, [R5, #WK_Flags]
m_sent
        LDMFD   R13!, {R0-R8, PC}

; ---------------------------------------------------------------------
; The status lines

m_title
        STMFD   R13!, {R0-R1, R14}
        MOV     R0, #0
        MOV     R1, #0
        BL      s_tab
        ADR     R0, m_title_text
        SWI     XOS_Write0
        LDR     R0, [R12, #M_Station]
        BL      m_print_number
        LDMFD   R13!, {R0-R1, PC}
m_title_text
        EQUS    "Distributed Mandelbrot: coordinator on station "
        EQUB    0
        ALIGN

; "Workers 3   Tiles 120 of 300   Time 12.3s", or once it's done,
; "Complete: 300 tiles in 41.5s. Press a key."
m_status
        STMFD   R13!, {R0-R1, R14}
        SWI     XOS_ReadMonotonicTime
        ADD     R1, R0, #50
        STR     R1, [R12, #M_Redraw]
        LDR     R1, [R12, #M_Complete]
        CMP     R1, #0
        BNE     m_status_complete
        LDR     R1, [R12, #M_Start]
        SUB     R1, R0, R1
        STMFD   R13!, {R1}
        MOV     R0, #0
        MOV     R1, #1
        BL      s_tab
        LDMFD   R13!, {R1}
        ADR     R0, m_status_workers
        SWI     XOS_Write0
        LDR     R0, [R12, #M_Workers]
        BL      m_print_number
        ADR     R0, m_status_tiles
        SWI     XOS_Write0
        LDR     R0, [R12, #M_Done]
        BL      m_print_number
        ADR     R0, m_status_time
        SWI     XOS_Write0
        MOV     R0, R1
        BL      m_print_seconds
        ADR     R0, m_status_end
        SWI     XOS_Write0
        LDMFD   R13!, {R0-R1, PC}
m_status_complete
        MOV     R0, #0
        MOV     R1, #1
        BL      s_tab
        ADR     R0, m_status_done
        SWI     XOS_Write0
        LDR     R0, [R12, #M_End]
        LDR     R1, [R12, #M_Start]
        SUB     R0, R0, R1
        BL      m_print_seconds
        ADR     R0, m_status_key
        SWI     XOS_Write0
        LDMFD   R13!, {R0-R1, PC}
m_status_workers
        EQUS    "Workers "
        EQUB    0
m_status_tiles
        EQUS    "   Tiles "
        EQUB    0
m_status_time
        EQUS    " of 300   Time "
        EQUB    0
m_status_end
        EQUS    "      "
        EQUB    0
m_status_done
        EQUS    "Complete: 300 tiles in "
        EQUB    0
m_status_key
        EQUS    ". Press a key.               "
        EQUB    0
        ALIGN

m_print_number
        STMFD   R13!, {R1, R14}
        ADD     R1, R12, #M_Num
        BL      s_number
        LDMFD   R13!, {R1, PC}

; Centiseconds R0 as seconds: "41.5s"
m_print_seconds
        STMFD   R13!, {R0-R2, R14}
        MOV     R1, #0          ; tenths
m_seconds_tenths
        CMP     R0, #10
        SUBHS   R0, R0, #10
        ADDHS   R1, R1, #1
        BHS     m_seconds_tenths
        MOV     R0, #0          ; seconds
m_seconds_whole
        CMP     R1, #10
        SUBHS   R1, R1, #10
        ADDHS   R0, R0, #1
        BHS     m_seconds_whole
        BL      m_print_number
        MOV     R0, #'.'
        SWI     XOS_WriteC
        ADD     R0, R1, #'0'
        SWI     XOS_WriteC
        MOV     R0, #'s'
        SWI     XOS_WriteC
        LDMFD   R13!, {R0-R2, PC}

        LTORG
        INCLUDE "shared.s"
        ALIGN
mandel_end
