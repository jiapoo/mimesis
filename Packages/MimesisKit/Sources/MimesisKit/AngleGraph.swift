import AreteMedia
import Charts
import SwiftUI

/// In the sidebar: a joint's angle through the segment, clip A against clip B on the same time axis
/// (seconds on screen from the segment's start, so matched moments sit one above the other), the
/// values at the playhead, and how long each clip takes to reach each sync point.
struct AngleGraph: View {
    let comparison: Comparison

    private struct Sample: Identifiable {
        let clip: String
        let at: Double
        let degrees: Double
        var id: String { "\(clip)-\(at)" }
    }

    private var loaded: [(letter: String, clip: Clip)] {
        zip(["A", "B"], comparison.clips).filter { $0.1.isLoaded }.map { (letter: $0.0, clip: $0.1) }
    }

    private func aspect(_ clip: Clip) -> CGFloat {
        let size = clip.engine.videoSize
        return size.height > 0 ? size.width / size.height : 1
    }

    private var start: Double { comparison.canLink ? comparison.range.lowerBound : 0 }

    /// Where a clip's own time falls on the shared axis.
    private func axis(_ clip: Clip, _ time: Double) -> Double {
        comparison.canLink ? comparison.linkedTime(of: clip, at: time) - start : time - clip.trimStart
    }

    private var samples: [Sample] {
        loaded.flatMap { letter, clip -> [Sample] in
            guard let track = clip.poseTrack, track.state == .ready else { return [] }
            return track.curve(comparison.graphAngle, aspect: aspect(clip)).map {
                Sample(clip: letter, at: axis(clip, $0.time), degrees: $0.degrees)
            }
        }
    }

    private var tracking: Double? {
        let states = loaded.compactMap { $0.clip.poseTrack?.state }
        let progress: [Double] = states.compactMap { if case .preparing(let done) = $0 { return done } else { return nil } }
        return progress.isEmpty ? nil : progress.reduce(0, +) / Double(progress.count)
    }

    private var tracked: Bool { loaded.contains { $0.clip.poseTrack?.state == .ready } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ANGLES").font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    Section("Graph") {
                        ForEach(JointAngle.allCases) { angle in
                            Button { comparison.graphAngle = angle } label: {
                                if comparison.graphAngle == angle { Label(angle.title, systemImage: "checkmark") } else { Text(angle.title) }
                            }
                        }
                    }
                    Section("Written on the skeleton") {
                        ForEach(JointAngle.allCases) { angle in
                            Toggle(angle.title, isOn: Binding(
                                get: { comparison.skeletonAngles.contains(angle) },
                                set: { on in
                                    if on { comparison.skeletonAngles.insert(angle) } else { comparison.skeletonAngles.remove(angle) }
                                }))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(comparison.graphAngle.title).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(Theme.raised, in: Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Which joint's angle to graph, and which angles to write on the skeleton")
            }

            if let tracking {
                ProgressView(value: tracking) { Text("Finding the body… \(Int(tracking * 100)) %").font(.system(size: 11)) }
            } else if !tracked {
                Button {
                    for (_, clip) in loaded { clip.trackPose() }
                } label: {
                    Label("Measure the body in this segment", systemImage: "figure.arms.open")
                }
                .buttonStyle(ChipStyle(active: true))
                .help("Follow the body through each clip's In to Out, to graph its joint angles")
                if let why = failure {
                    Text(why).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            } else {
                chart
                readout
                Button("Measure again") { for (_, clip) in loaded { clip.poseTrack = nil; clip.trackPose() } }
                    .buttonStyle(ChipStyle())
                    .help("After changing In or Out: follow the body through the new stretch")
            }
            timing
        }
    }

    private var failure: String? {
        for (_, clip) in loaded { if case .failed(let why)? = clip.poseTrack?.state { return why } }
        return nil
    }

    private var playhead: Double? {
        if comparison.linked { return comparison.position - start }
        guard let clip = comparison.focused else { return nil }
        return axis(clip, clip.engine.currentTime)
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.at), y: .value("Angle", sample.degrees))
                    .foregroundStyle(by: .value("Clip", sample.clip))
                    .interpolationMethod(.catmullRom)
            }
            if let playhead {
                RuleMark(x: .value("Now", playhead))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale(["A": Theme.accent, "B": Color(red: 0.3, green: 0.85, blue: 1)])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))°").font(.system(size: 9)) } }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel { if let v = value.as(Double.self) { Text(v.formatted(.number.precision(.fractionLength(1)))).font(.system(size: 9)) } }
            }
        }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 140)
        .help("\(comparison.graphAngle.title) angle through the segment; the white line is the playhead")
    }

    /// "A 143°   B 151°   8° apart"
    private var readout: some View {
        let values: [(String, Double)] = loaded.compactMap { letter, clip in
            guard let degrees = clip.poseTrack?.pose(at: clip.engine.currentTime)?.angle(comparison.graphAngle, aspect: aspect(clip)) else { return nil }
            return (letter, degrees)
        }
        return HStack(spacing: 10) {
            ForEach(values, id: \.0) { letter, degrees in
                Text("\(letter) \(Int(degrees.rounded()))°")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(letter == "A" ? Theme.accent : Color(red: 0.3, green: 0.85, blue: 1))
            }
            if values.count == 2 {
                Text("\(Int(abs(values[0].1 - values[1].1).rounded()))° apart")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// How long each clip takes, at its own pace, from its In to each sync point and to its Out.
    @ViewBuilder private var timing: some View {
        let rows = timingRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("TIMING").font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundStyle(Theme.secondary)
                    .padding(.top, 4)
                ForEach(rows, id: \.label) { row in
                    HStack {
                        Text(row.label).font(.system(size: 12))
                        Spacer()
                        ForEach(Array(row.values.enumerated()), id: \.offset) { index, value in
                            Text(value.map { "\(loaded.count == 2 ? (index == 0 ? "A " : "B ") : "")\(clock($0))" } ?? "–")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(index == 0 ? Theme.accent : Color(red: 0.3, green: 0.85, blue: 1))
                                .frame(minWidth: 62, alignment: .trailing)
                        }
                    }
                }
            }
            .help("Each clip's own time (at its real speed) from its In to each sync point, and to its Out")
        }
    }

    private var timingRows: [(label: String, values: [Double?])] {
        let clips = loaded.map(\.clip)
        guard !clips.isEmpty else { return [] }
        var rows: [(label: String, values: [Double?])] = []
        let most = clips.map(\.syncs.count).max() ?? 0
        for index in 0..<most {
            rows.append((label: "To sync \(index + 1)", values: clips.map { clip in
                clip.syncs.indices.contains(index) ? clip.syncs[index] - clip.trimStart : nil
            }))
        }
        if clips.contains(where: { $0.trimEnd != nil }) {
            rows.append((label: "In to Out", values: clips.map { clip in clip.trimEnd.map { $0 - clip.trimStart } }))
        }
        return rows
    }
}
