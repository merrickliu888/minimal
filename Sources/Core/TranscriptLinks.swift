import Foundation

enum TranscriptLinks {
    enum OpeningResult: Equatable {
        case handled
        case systemAction
        case failed
    }

    static func baseURL(workingDirectory: String?) -> URL? {
        guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
    }

    static func open(_ url: URL, fileOpener: (URL) -> Bool) -> OpeningResult {
        guard url.isFileURL else { return .systemAction }
        return fileOpener(url) ? .handled : .failed
    }
}
