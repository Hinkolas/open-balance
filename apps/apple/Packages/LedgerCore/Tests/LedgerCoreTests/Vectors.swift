import Foundation

/// Loads spec/vectors/<name> relative to this file: the same JSON every
/// implementation runs.
func vectors(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() } // → repo root
    return try Data(contentsOf: url.appendingPathComponent("spec/vectors/\(name)"))
}
