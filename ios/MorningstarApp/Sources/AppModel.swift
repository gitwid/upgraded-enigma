import Foundation
import Observation
import MorningstarKit

/// Owns the single local store and the transient capture-draft state.
/// The store lives in Application Support (local-first; no cloud, no
/// network). Draft text lives only here until Play commits it.
/// One place that knows where the store lives, shared by the app and by the
/// App Intent, which may run while the app is not in memory.
enum AppPaths {
    static var storeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Morningstar", isDirectory: true)
    }
}

@Observable
final class AppModel {
    let store: SQLiteStore
    private(set) var captures: [Capture] = []
    /// Whether the archive currently includes hidden captures.
    var includeHidden = false {
        didSet { refresh() }
    }

    // Transient capture draft — the three channels plus optional detail.
    var observation = ""
    var phenomenology = ""
    var action = ""
    var recordedAt = ""
    var source = ""
    var recallLatency = ""

    // The Mind wander pane: purposeless writing that is NEVER persisted.
    var wander = ""

    /// Cached so the re-entry line does not query on every render. Reflects
    /// the true last capture, hidden or not.
    private var lastCapture: (sequenceNumber: Int, committedAt: String)?

    init() {
        // A store that cannot be opened leaves nothing to record into; the
        // instrument has no meaningful degraded mode.
        store = try! SQLiteStore(directory: AppPaths.storeDirectory)
        refresh()
    }

    /// Records a blurt at event speed — see `CommitQuickCaptureIntent`.
    @discardableResult
    func commitQuick(_ text: String) throws -> Capture {
        let capture = try store.commitQuickCapture(text, captureSource: "quick-app")
        refresh()
        return capture
    }

    func refresh() {
        captures = (try? store.captures(includeHidden: includeHidden)) ?? []
        if let last = try? store.captures(includeHidden: true).last {
            lastCapture = (last.sequenceNumber, last.committedAt)
        } else {
            lastCapture = nil
        }
    }

    var reentryLine: String? {
        guard let last = lastCapture,
              let committed = ISO8601DateFormatter.morningstar.date(from: last.committedAt)
        else { return nil }
        let elapsed = Date().timeIntervalSince(committed)
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
        refresh()
        return capture
    }

    /// Clear the draft after a commit (or an abandoned journey). The wander
    /// pane is cleared here too — it is never written anywhere.
    func resetDraft() {
        observation = ""; phenomenology = ""; action = ""
        recordedAt = ""; source = ""; recallLatency = ""
        wander = ""
    }

    // MARK: - annotations

    /// Bumped on each annotation so observing views recompute; the store's
    /// query results aren't themselves observable.
    private(set) var annotationsVersion = 0

    func annotations(for capture: Capture) -> [Annotation] {
        _ = annotationsVersion  // read so SwiftUI tracks this dependency
        return (try? store.annotations(for: capture.id)) ?? []
    }

    @discardableResult
    func annotate(_ capture: Capture, type: String, body: String) -> Annotation? {
        let annotation = try? store.annotate(captureID: capture.id, type: type, body: body)
        annotationsVersion += 1
        return annotation
    }

    // MARK: - visibility & deletion

    func hide(_ capture: Capture) {
        try? store.hide(captureID: capture.id)
        refresh()
    }

    func unhide(_ capture: Capture) {
        try? store.unhide(captureID: capture.id)
        refresh()
    }

    /// Permanent, irreversible deletion of a capture's content. See the
    /// confirmation copy in ArchiveView for the trade-off this carries.
    func redact(_ capture: Capture) {
        try? store.redact(captureID: capture.id)
        annotationsVersion += 1
        refresh()
    }

    // MARK: - audit

    func verify() -> IntegrityReport {
        (try? store.verifyIntegrity()) ?? IntegrityReport()
    }
}

extension ISO8601DateFormatter {
    static let morningstar: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

func humanize(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let days = total / 86400, hours = (total % 86400) / 3600, minutes = (total % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "less than a minute"
}
