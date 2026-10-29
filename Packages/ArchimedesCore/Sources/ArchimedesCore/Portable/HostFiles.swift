import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#endif

/// The few file operations whose spelling differs by host C library.
enum HostFiles {
    /// POSIX `open(2)`, from whichever C library the host has (it's shadowed
    /// by types' own `open` methods, so callers can't name it directly).
    static func openFD(_ path: String, _ flags: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.open(path, flags)
        #elseif canImport(Glibc)
        Glibc.open(path, flags)
        #else
        WASILibc.open(path, flags)
        #endif
    }

    /// Writes `data`, atomically where the host supports temporary files
    /// (WASI doesn't).
    static func write(_ data: Data, to path: String) throws {
        #if os(WASI)
        try data.write(to: URL(fileURLWithPath: path))
        #else
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        #endif
    }
}
