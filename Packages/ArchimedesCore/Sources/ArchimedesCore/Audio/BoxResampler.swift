/// Area-averaging (box filter) resampler from the VIDC byte rate to a fixed
/// host rate. Each guest sample covers outputRate/inputRate output samples:
/// more than one when upsampling (1 channel at 48 µs is 20.8 kHz), a fraction
/// when downsampling (4 or 8 channels give 83–166 kHz byte rates).
public struct BoxResampler {
    public let outputRate: Double
    /// VIDC time-multiplexes channels, so each of N channels reaches the DAC
    /// 1/N of the time and centre-panned output peaks at half scale.
    public var gain: Float
    private var accL: Float = 0, accR: Float = 0, fill: Double = 0

    public init(outputRate: Double, gain: Float = 2) {
        self.outputRate = outputRate
        self.gain = gain
    }

    /// Feed one guest sample; `emit` is called for each completed output sample.
    @inline(__always)
    public mutating func push(left: Float, right: Float, inputRate: Double, emit: (Float, Float) -> Void) {
        var span = outputRate / inputRate
        while span > 0 {
            let take = min(span, 1 - fill)
            accL += left * Float(take); accR += right * Float(take)
            fill += take; span -= take
            if fill >= 1 - 1e-9 {
                emit(max(-1, min(1, accL * gain)), max(-1, min(1, accR * gain)))
                accL = 0; accR = 0; fill = 0
            }
        }
    }
}
