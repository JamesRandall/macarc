import ArchimedesCore
import SwiftUI

/// The rewind history as a scrubber: pick a moment and go back to it.
struct RewindSheet: View {
    let machine: MachineController
    @Environment(\.dismiss) private var dismiss
    @State private var points: [UInt64] = []
    @State private var now: UInt64 = 0
    @State private var index = 0.0
    @State private var thumbnail: CGImage?
    @State private var wasPaused = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Rewind").font(.title2)
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.black)
                }
            }
            .frame(width: 416, height: 288)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if points.count > 1 {
                Slider(value: $index, in: 0...Double(points.count - 1), step: 1)
                Text(label).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("No history yet: rewind keeps the last minute as the machine runs.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rewind to Here") {
                    if points.indices.contains(Int(index)) { machine.seek(to: points[Int(index)]) }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(points.count < 2)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            wasPaused = machine.paused
            machine.setPaused(true)
            (points, now) = await machine.rewindPoints()
            index = Double(max(0, points.count - 1))
            thumbnail = await machine.rewindThumbnail(Int(index))
        }
        .onChange(of: index) {
            let i = Int(index)
            Task { thumbnail = await machine.rewindThumbnail(i) }
        }
    }

    private var label: String {
        guard points.indices.contains(Int(index)) else { return "" }
        let back = Double(now - min(now, points[Int(index)])) / Double(MasterClock.ticksPerSecond)
        return back < 0.05 ? "Now" : String(format: "%.1f seconds ago", back)
    }

    private func close() {
        machine.setPaused(wasPaused)
        dismiss()
    }
}
