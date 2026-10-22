# MacArch debugger for VS Code

Write ARM assembler and debug it on MacArch's emulated Acorn Archimedes:
press F5 and it is assembled, loaded and run, with breakpoints in your
source (conditional ones, hit counts and log points too), stepping over,
into, out of and back, registers and flags you can edit, the banked
registers, memory, disassembly, watchpoints (data breakpoints) on any
address, and what the program prints in the debug console. It talks to
MacArch over the Debug Adapter Protocol on localhost port 3200 (Settings >
Debugging in MacArch), and starts MacArch if it isn't running.

## Install

    cd Tools/vscode-macarch
    npx @vscode/vsce package --no-dependencies --allow-missing-repository --skip-license
    code --install-extension macarch-debug-0.1.0.vsix

Or, to try it, open this folder in VS Code and press F5 (Extension
Development Host).

## Use

Open a `.s` (or `.arm`) file and press F5: MacArch assembles it, goes to
the `*` prompt (F12 from the desktop), loads the code at its `ORG` (default
&8000), and starts it with `*Go`. Programs end with `SWI OS_Exit`. Or in
`.vscode/launch.json`:

    {
      "type": "macarch",
      "request": "launch",
      "name": "Assemble and run",
      "source": "${workspaceFolder}/game.s",
      "stopOnEntry": true
    }

`model` switches the machine first (`A3000`, `A5000`, `A440/1`...), `disc`
puts a floppy image in drive 0, and `program` (with `loadAddress` and
`execAddress`) runs a binary built some other way, with `symbols` for a
label file. `attach` debugs whatever is running.

Assembly errors appear in the debug console as `file:line: message`.

The assembler takes BBC BASIC V's assembler syntax as a file of its own,
so `.label`, `ADDEQS`, `LDMFD R13!, {R0-R3, PC}^`, `SWI "OS_Write0"`,
`EQUS`/`EQUB`/`EQUD` and `ALIGN` all work, along with `LDR R0, =value`,
`ADR`/`ADRL`, `INCLUDE`, `name EQU value` and comments after `;` or `\`.
See `Examples/hello-arm`, and the README's Assembler section.

In the debug console, expressions use registers, flags, symbols and
memory: `R0`, `PC+4`, `[R1]` (a byte), `{R13}` (a word), `greeting`,
`hello.s:20` (the address of a line). Hovering over a label shows its
address and the memory there.

## Licence

As MacArch's (see the repository).
