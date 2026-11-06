// The Phase 0 masking test from the command line.
//
//   swift run -c release mask-probe <video> [--start 3] [--seconds 2] [--out folder]
//
// Prints how fast each method is and how often it finds nobody, and writes sheet.png:
// frames spread over the span, each as frame | person mask | lift subject.

import Foundation
import MimesisKit

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let at = arguments.firstIndex(of: name), at + 1 < arguments.count else { return nil }
    let value = arguments[at + 1]
    arguments.removeSubrange(at...(at + 1))
    return value
}

let start = option("--start").flatMap(Double.init) ?? 0
let seconds = option("--seconds").flatMap(Double.init) ?? 2
let out = URL(fileURLWithPath: option("--out") ?? ".", isDirectory: true)

guard let path = arguments.first else {
    print("usage: mask-probe <video> [--start s] [--seconds s] [--out folder]")
    exit(2)
}

do {
    let report = try await MaskProbe.run(url: URL(fileURLWithPath: path), start: start, duration: seconds)
    print("\(report.frames.count) frames at \(Int(report.size.width))×\(Int(report.size.height)), "
        + "\(Int(report.frameRate.rounded())) fps")
    for line in MaskProbe.summary(report) { print(line) }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    if let sheet = MaskProbe.contactSheet(report), let data = MaskProbe.png(sheet) {
        let file = out.appendingPathComponent("sheet.png")
        try data.write(to: file)
        print("Wrote \(file.path)")
    }
} catch {
    print("mask-probe: \(error.localizedDescription)")
    exit(1)
}
