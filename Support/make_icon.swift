// Packages the image generated in chat. Never redraw the approved artwork.
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/AppIcon.icns"
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AppIcon.png")
guard FileManager.default.fileExists(atPath: source.path) else { fatalError("Missing generated AppIcon.png") }
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("SiriAI-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "IconPackaging", code: Int(process.terminationStatus)) }
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try run("/usr/bin/sips", ["-z", "\(size * scale)", "\(size * scale)", source.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output])
