import Foundation

enum TranscriptLinks {
    static func baseURL(workingDirectory: String?) -> URL? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
    }
}
