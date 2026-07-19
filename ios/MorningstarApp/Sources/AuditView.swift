import SwiftUI
import MorningstarKit

/// The expandable audit surface. Integrity conditions are instrument states,
/// not user failures: warnings are informational; errors mean the record no
/// longer verifies. Claims tamper evidence, not cryptographic proof.
struct AuditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var report: IntegrityReport?

    var body: some View {
        NavigationStack {
            List {
                let r = report ?? model.verify()
                Section {
                    if r.ok {
                        Label("Integrity check passed", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    } else {
                        Label("Integrity check failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if !r.errors.isEmpty {
                    Section("Errors") {
                        ForEach(r.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                }
                if !r.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(r.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                }
                Section("Counts") {
                    LabeledContent("events", value: "\(r.eventCount)")
                    LabeledContent("captures", value: "\(r.captureCount)")
                    LabeledContent("annotations", value: "\(r.annotationCount)")
                    LabeledContent("interpretations", value: "\(r.interpretationCount)")
                }
                Section {
                    Text("Hashes provide tamper evidence for this local store — not a cryptographic guarantee against someone with full access to the device.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Audit")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Re-check") { report = model.verify() }
                }
            }
            .onAppear { report = model.verify() }
        }
    }
}
