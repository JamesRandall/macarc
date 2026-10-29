// A WASI reactor: the host calls `_initialize`, then the exports in
// Exports.swift. Nothing runs here. (Built natively only so the package
// builds everywhere; it does nothing there.)
