# Debugging BBC BASIC

`primes.bas` is a BBC BASIC program to debug, in VS Code (with the MacArch
extension, Tools/vscode-macarch) or in MacArch's own debugger.

In VS Code, open this folder and press F5 in `primes.bas`, or pick a launch
configuration: one stops at the first statement, the other runs on an A5000.
MacArch goes to BASIC's prompt (from the desktop: F12, then `BASIC`), and the
program is tokenised, loaded at PAGE and RUN. Set breakpoints in the gutter
(on lines without numbers, which are numbered on in tens as BASIC would:
`MODE 7` is line 20), with conditions in BASIC (`n%>50`) or log messages
(`n%={n%}`). F10, F11 and Shift-F11 step a statement at a time over, into and
out of PROCs and FNs. The Variables view shows `FNprime`'s LOCALs `d%` and
`prime%`, and the program's variables; hover over one, or evaluate BASIC
expressions in the debug console (`count%*2`). Errors stop where they happen
(the BASIC errors exception breakpoint): try changing `d%=3` to `d%=0`.

In MacArch, drop `primes.bas` on the machine at BASIC's prompt to run it.
Open the debugger (Debug ▸ Show Debugger, ⌥⌘D), choose BASIC in its toolbar and click
a line's gutter.
