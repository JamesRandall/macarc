# Hello, ARM

A small ARM program for MacArch: it prints a greeting, then counts down
from 5, calling a subroutine for each digit.

- In VS Code, with the MacArch extension (Tools/vscode-macarch): open
  this folder, set a breakpoint in hello.s, and press F5. MacArch
  assembles it, loads it at &8000 from the `*` prompt and runs it with
  `*Go`; what it prints appears in the debug console.
- From an agent: `assemble` with `source: hello.s`, or with `run: false`,
  then `set_breakpoint hello.s:19` and `run_command *Go 8000`.
- From a terminal: `macarch-cli assemble hello.s --list` writes hello.bin
  and prints the listing.
