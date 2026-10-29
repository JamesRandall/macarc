// Plays interleaved stereo float32 chunks from the emulation worker (sent
// over this node's port). A small ring buffer absorbs scheduling jitter:
// silence when it runs dry, the oldest samples dropped when it overfills.

class ArcAudio extends AudioWorkletProcessor {
  constructor() {
    super();
    this.size = 1 << 16; // frames (~1.4 s at 48 kHz)
    this.left = new Float32Array(this.size);
    this.right = new Float32Array(this.size);
    this.read = 0;
    this.write = 0;
    this.maxLatency = Math.round(sampleRate * 0.25);
    this.port.onmessage = (e) => {
      if (e.data === 'clear') { this.read = this.write = 0; return; }
      const s = e.data;
      for (let i = 0; i + 1 < s.length; i += 2) {
        this.left[this.write] = s[i];
        this.right[this.write] = s[i + 1];
        this.write = (this.write + 1) % this.size;
      }
      const queued = (this.write - this.read + this.size) % this.size;
      if (queued > this.maxLatency) this.read = (this.write - Math.round(sampleRate * 0.08) + this.size) % this.size;
    };
  }

  process(_inputs, outputs) {
    const out = outputs[0];
    const l = out[0], r = out[1] ?? out[0];
    for (let i = 0; i < l.length; i++) {
      if (this.read === this.write) { l[i] = 0; r[i] = 0; continue; }
      l[i] = this.left[this.read];
      r[i] = this.right[this.read];
      this.read = (this.read + 1) % this.size;
    }
    return true;
  }
}

registerProcessor('arc-audio', ArcAudio);
