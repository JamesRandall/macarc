import CGtk
import CSDL3
import Foundation
import Glibc

// LinuxArch: MacArch's Acorn Archimedes, as a GTK4 and libadwaita app.

// A connection (an agent, an editor) going away mid-write mustn't kill the
// app.
signal(SIGPIPE, SIG_IGN)
// SDL (sound) leaves Ctrl+C and SIGTERM to the app, which quits properly on
// them (see LinuxArchApp).
SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1")

let status = MainActor.assumeIsolated {
    MainLoop.runDispatchMainQueue()
    return LinuxArchApp.shared.run()
}
exit(status)
