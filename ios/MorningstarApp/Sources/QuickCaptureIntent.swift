import AppIntents
import MorningstarKit

/// Capture at event speed, without opening the app: Shortcuts, Siri, the
/// Action button, a Lock Screen shortcut, or a Home Screen tile.
///
/// The protocol has always recorded `recall_latency` as an admission that
/// memory degrades between an event and the writing of it. Everything else in
/// the app widens that gap — unlock, find the icon, walk four stages. This
/// closes it, at the cost of structure: what you say lands in the `unsorted`
/// channel, honestly labelled as not yet separated into layers.
///
/// Note what this deliberately does NOT do: it never claims the capture was
/// immediate. It records the path taken (`capture_source`), which is a fact.
/// Whether you spoke at the moment or three hours later is yours to state.
struct CommitQuickCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Record a capture"
    static var description = IntentDescription(
        "Records what just happened, unsorted, without opening the app. "
        + "You can separate it into observation, experience, and action later — "
        + "that is added alongside the original, which never changes.")

    /// Stays out of the app: the point is to not be pulled into a screen.
    static var openAppWhenRun = false

    @Parameter(title: "What happened?",
               requestValueDialog: "What do you want to record?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing was recorded — there was no text.")
        }
        // A short-lived connection of its own: the intent may run while the app
        // is not in memory. SQLite serializes the write against any other.
        let store = try SQLiteStore(directory: AppPaths.storeDirectory)
        defer { store.close() }
        let capture = try store.commitQuickCapture(trimmed, captureSource: "quick-intent")
        return .result(dialog: IntentDialog(
            "Recorded as capture \(String(format: "%03d", capture.sequenceNumber))."))
    }
}

struct MorningstarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CommitQuickCaptureIntent(),
            phrases: [
                "Record in \(.applicationName)",
                "Capture in \(.applicationName)",
                "Take this down in \(.applicationName)",
            ],
            shortTitle: "Record",
            systemImageName: "square.and.pencil")
    }
}
