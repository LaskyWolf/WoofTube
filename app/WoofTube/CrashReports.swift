import Foundation
import MetricKit

/// iOS hands over a report at the launch after a crash or a long freeze. They stay on this phone until shared from Diagnostics.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()
    private static let kept = 10
    private static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "CrashReports", directoryHint: .isDirectory)
    }

    /// Newest first.
    static var saved: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func start() {
        MXMetricManager.shared.add(self)
        store(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        store(payloads)
    }

    private func store(_ payloads: [MXDiagnosticPayload]) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            guard crashes + hangs > 0 else { continue }
            let date = payload.timeStampEnd.ISO8601Format().replacingOccurrences(of: ":", with: "-")
            let name = "\(date) \(crashes > 0 ? "crash" : "hang").json"
            try? payload.jsonRepresentation().write(to: Self.folder.appending(path: name), options: .atomic)
        }
        for file in Self.saved.dropFirst(Self.kept) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
