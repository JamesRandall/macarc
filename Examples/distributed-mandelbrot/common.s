; Distributed Mandelbrot: the definitions the coordinator (mandel.s) and
; the worker (worker.s) share. See protocol.md.

; SWIs (the X forms: errors come back with V set)
XOS_WriteC              * &20000
XOS_Write0              * &20002
XOS_NewLine             * &20003
XOS_Byte                * &20006
XOS_Exit                * &20011
XOS_GetEnv              * &20010
XOS_Module              * &2001E
XOS_ReadVduVariables    * &20031
XOS_ReadMonotonicTime   * &20042
XOS_WriteN              * &20046
XOS_ConvertCardinal4    * &200D8
XEconet_CreateReceive   * &60000
XEconet_ExamineReceive  * &60001
XEconet_ReadReceive     * &60002
XEconet_AbandonReceive  * &60003
XEconet_DoTransmit      * &60009
XEconet_ReadLocalStationAndNet * &6000A

; Ports (application choices, not Acorn's)
PortCoordinator * &C0           ; HELLO, READY, RESULT, STATUS
PortWorker      * &C1           ; WELCOME, ASSIGN, ACK, COMPLETE, DISCOVER, START, STOP

; Econet
Control         * &80
Received        * 9             ; Econet_ExamineReceive's status
RxSize          * 544           ; the largest message (RESULT: 14 + 11 + 512), and some

; Message types
MsgHello        * 1
MsgWelcome      * 2
MsgReady        * 3
MsgAssign       * 4
MsgResult       * 5
MsgAck          * 6
MsgComplete     * 8
MsgDiscover     * 11
MsgStart        * 13
MsgStop         * 16
MsgStatus       * 17

; The header: "MA", version, type, runId (4), messageId (2), sender, flags, payload length (2)
HdrMagic        * 0
HdrVersion      * 2
HdrType         * 3
HdrRunId        * 4
HdrMessageId    * 8
HdrSender       * 10
HdrFlags        * 11
HdrLength       * 12
HdrSize         * 14
Version         * 1

; Payload lengths
LenHello        * 4
LenWelcome      * 8
LenReady        * 1
LenAssign       * 28
LenResultHead   * 11
LenAck          * 5
LenComplete     * 2
LenDiscover     * 4
LenStart        * 5
LenStop         * 4
LenStatus       * 7

; STATUS states, and ACK statuses
StateRunning    * 2
StateStopping   * 3
AckAccepted     * 0
AckDuplicate    * 1
AckStale        * 2

; The picture: MODE 12, 640 x 256 in 16 colours. The top 16 rows are the
; status lines; the picture is the 240 rows below, in 32 x 16 tiles.
ScreenMode      * 12
BytesPerRow     * 320
ImageTop        * 16
ImageWidth      * 640
ImageHeight     * 240
TileWidth       * 32
TileHeight      * 16
TileColumns     * 20
TileRows        * 15
Tiles           * 300
TileSize        * TileWidth * TileHeight
MaxIterations   * 64

; Fixed point 4.28
Two             * 2 << 28
Four            * 4 << 28

; The default view, in 4.28: real -2.5 ... +0.7 across the 640 columns,
; imag +1.2 at the top row going down 0.01 a row. The steps are 3.2 / 640
; and -2.4 / 240, truncated towards zero; pixel (x, y) is
; (ViewLeft + x * StepReal, ViewTop + y * StepImag).
ViewLeft        * -671088640    ; -2.5
ViewTop         * 322122547     ; 1.2
StepReal        * 1342177       ; 0.005
StepImag        * -2684354      ; -0.01

; Colours: 0 inside the set, 1-14 the bands (they cycle), 15 text
Bands           * 14
TextColour      * 15

; Timing, in centiseconds (the monotonic clock)
HelloEvery      * 100
ReadyEvery      * 200
ResultEvery     * 200
CompleteEvery   * 300
TileTimeout     * 2000
SilentTimeout   * 1000          ; a worker heard from less often is unresponsive
ProbeEvery      * 100

; Stations the coordinator looks for workers on
FirstProbe      * 1
LastProbe       * 63
