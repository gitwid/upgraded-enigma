import Foundation
import Observation
import MorningstarKit

/// Owns the single local store and the transient capture-draft state.
/// The store lives in Application Support (local-first; no cloud, no
/// network). Draft text lives only here until Play commits it.
@Observable
final class AppModel {
    let store: FileEventStore
    var captures: [Capture] = []

    // Transient capture draft — the three channels plus optional detail.
    var observation = ""
    var phenomenology = ""
    var action = ""
    var recordedAt = ""
    var source = ""
    var recallLatency = ""

    // The Mind wander pane: purposeless writing that is NEVER persisted.
    var wander = ""

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Morningstar", isDirectory: true)
        // A failure here is unrecoverable for the instrument; surface loudly.
        store = try! FileEventStore(directory: base)
        captures = store.captures
    }

    var reentryLine: String? {
        guard let last = captures.last else { return nil }
        let elapsed = Date().timeIntervalSince(
            ISO8601DateFormatter.morningstar.date(from: last.createdAt) ?? Date())
        return "Your previous capture (capture \(String(format: "%03d", last.sequenceNumber))) "
            + "was committed \(humanize(elapsed)) ago."
    }

    func leakageWarnings() -> [LeakageWarning] {
        checkLeakage(observation: observation, phenomenology: phenomenology, action: action)
    }

    @discardableResult
    func commit() throws -> Capture {
        let capture = try store.commitCapture(
            observation: observation, phenomenology: phenomenology, action: action,
            recordedAt: recordedAt.isEmpty ? nil : recordedAt,
            source: source.isEmpty ? nil : source,
            recallLatency: recallLatency.isEmpty ? nil : recallLatency,
            captureSource: "ios-app")
        captures = store.captures
        return capture
    }

    /// Clear the draft after a commit (or an abandoned journey). The wander
    /// pane is cleared here too — it is never written anywhere.
    func resetDraft() {
        observation = ""; phenomenology = ""; action = ""
        recordedAt = ""; source = ""; recallLatency = ""
        wander = ""
    }

    func annotations(for capture: Capture) -> [Annotation] {
        _ = annotationsVersion  // read so SwiftUI tracks this dependency
        return store.annotations(for: capture.id)
    }

    /// Bumped on each annotation so observing views recompute. The store's
    /// own arrays aren't @Observable, so AppModel carries the signal.
    private(set) var annotationsVersion = 0

    @discardableResult
    func annotate(_ capture: Capture, type: String, body: String) -> Annotation? {
        let annotation = try? store.annotate(captureID: capture.id, type: type, body: body)
        annotationsVersion += 1
        return annotation
    }

    func verify() -> IntegrityReport {
        (try? store.verifyIntegrity()) ?? IntegrityReport()
    }
}

extension ISO8601DateFormatter {
    static let morningstar: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

func humanize(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    let days = s / 86400, hours = (s % 86400) / 3600, minutes = (s % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "less than a minute"
}
