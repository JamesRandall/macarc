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

    /// Sets a file's modification time, if it can be. (Linux's Foundation
    /// gives dates before 1970 that aren't whole seconds a negative
    /// nanosecond count, which utimensat refuses: so it's done here.)
    static func setModificationDate(_ date: Date, path: String) {
        #if canImport(Glibc)
        let t = date.timeIntervalSince1970, seconds = t.rounded(.down)
        let mtime = timespec(tv_sec: Int(seconds), tv_nsec: min(999_999_999, Int((t - seconds) * 1e9)))
        // The access time is left alone (UTIME_OMIT, a macro Swift can't see).
        let times = [timespec(tv_sec: 0, tv_nsec: (1 << 30) - 2), mtime]
        _ = utimensat(AT_FDCWD, path, times, 0)
        #else
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
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
