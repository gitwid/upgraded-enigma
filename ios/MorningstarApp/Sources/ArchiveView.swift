import SwiftUI
import MorningstarKit

/// The committed record. Read-only by construction: captures are evidence
/// and never editable here — later material is an annotation. A plain-text
/// export (readable without the data model) goes out via the share sheet.
struct ArchiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.captures.isEmpty {
                    ContentUnavailableView(
                        model.includeHidden ? "No captures yet" : "Nothing in view",
                        systemImage: "circle.dotted",
                        description: Text(model.includeHidden
                            ? "Begin a capture from the hub."
                            : "Begin a capture from the hub, or show hidden captures."))
                } else {
                    List {
                        ForEach(model.captures.reversed(), id: \.id) { capture in
                            NavigationLink {
                                CaptureDetailView(capture: capture)
                            } label: {
                                row(for: capture)
                            }
                            .swipeActions(edge: .trailing) {
                                if capture.hidden {
                                    Button("Unhide") { model.unhide(capture) }
                                } else {
                                    Button("Hide") { model.hide(capture) }
                                        .tint(.gray)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Archive")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show hidden", isOn: Binding(
                            get: { model.includeHidden },
                            set: { model.includeHidden = $0 }))
                        ShareLink(item: textExport()) {
                            Label("Export as text", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func row(for capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Capture \(String(format: "%03d", capture.sequenceNumber))")
                    .font(.headline)
                if capture.hidden {
                    Text("hidden").font(.caption2).foregroundStyle(.secondary)
                }
                if capture.redacted {
                    Text("redacted").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(firstLine(capture))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func firstLine(_ capture: Capture) -> String {
        if capture.redacted { return "content permanently removed" }
        let source = [capture.observation, capture.phenomenology, capture.action]
            .first { !$0.isEmpty } ?? ""
        return source.split(separator: "\n").first.map(String.init) ?? "(empty)"
    }

    private func textExport() -> String {
        var out = ["MORNINGSTAR ARCHIVE", "app version: \(Morningstar.appVersion)", ""]
        // Exports carry the whole record, hidden captures included.
        for capture in (try? model.store.captures(includeHidden: true)) ?? [] {
            out.append("MORNINGSTAR — capture \(String(format: "%03d", capture.sequenceNumber))")
            out.append("schema: v\(capture.schemaVersion)  protocol: v\(capture.protocolVersion)")
            out.append("recorded: \(capture.recordedAt ?? capture.createdAt + " (machine timestamp)")")
            out.append("committed: \(capture.committedAt)")
            out.append("source: \(capture.source ?? "not stated")")
            if capture.hidden { out.append("NOTE: hidden from normal view") }
            if capture.redacted { out.append("NOTE: content permanently redacted by the user") }
            out.append("\nOBSERVATION\n-----------\n\(display(capture.observation))")
            out.append("\nPHENOMENOLOGY\n-------------\n\(display(capture.phenomenology))")
            out.append("\nACTION\n------\n\(display(capture.action))")
            for annotation in model.annotations(for: capture) {
                out.append("\n[\(annotation.type)] \(annotation.createdAt)\n\(annotation.body)")
            }
            out.append("""

                PROVENANCE
                ----------
                id: \(capture.id)
                integrity hash: \(capture.integrityHash)
                previous hash: \(capture.previousHash)
                """)
            out.append("\n" + String(repeating: "=", count: 60) + "\n")
        }
        return out.joined(separator: "\n")
    }

    private func display(_ text: String) -> String { text.isEmpty ? "(empty)" : text }
}

struct CaptureDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let capture: Capture
    @State private var annotationBody = ""
    @State private var annotationType = "note"
    @State private var confirmingDeletion = false

    var body: some View {
        List {
            Section("Observation") { Text(display(capture.observation)) }
            Section("Phenomenology") { Text(display(capture.phenomenology)) }
            Section("Action") { Text(display(capture.action)) }

            Section("Annotations") {
                let annotations = model.annotations(for: capture)
                if annotations.isEmpty {
                    Text("None yet. The capture is immutable; anything you add later lands here.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(annotations, id: \.id) { annotation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("[\(annotation.type)] \(annotation.createdAt)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(annotation.body)
                        }
                    }
                }
                if !capture.redacted {
                    Picker("Kind", selection: $annotationType) {
                        Text("note").tag("note")
                        Text("correction").tag("correction")
                        Text("context").tag("context")
                    }
                    TextField("Add an annotation", text: $annotationBody, axis: .vertical)
                        .lineLimit(2...5)
                    Button("Add annotation") {
                        model.annotate(capture, type: annotationType, body: annotationBody)
                        annotationBody = ""
                    }
                    .disabled(annotationBody.isEmpty)
                }
            }

            Section("Provenance") {
                LabeledContent("committed", value: capture.committedAt)
                LabeledContent("protocol", value: capture.protocolVersion)
                LabeledContent("schema", value: capture.schemaVersion)
                Text("integrity: \(capture.integrityHash)")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section {
                if capture.hidden {
                    Button("Unhide") { model.unhide(capture) }
                } else {
                    Button("Hide from normal view") { model.hide(capture) }
                }
                if !capture.redacted {
                    Button("Permanently delete…", role: .destructive) {
                        confirmingDeletion = true
                    }
                }
            } footer: {
                Text("Hiding keeps the evidence intact and is reversible. "
                     + "Permanent deletion is not.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Capture \(String(format: "%03d", capture.sequenceNumber))")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Permanently delete capture \(String(format: "%03d", capture.sequenceNumber))?",
            isPresented: $confirmingDeletion, titleVisibility: .visible
        ) {
            Button("Permanently delete", role: .destructive) {
                model.redact(capture)
                dismiss()
            }
            Button("Hide instead") { model.hide(capture) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                This conflicts with the append-only record, on purpose.

                It irreversibly blanks this capture's text, its annotations, and the ledger \
                entries that carried its content. The record of when the capture existed, its \
                ordering, and the hash chain remain, and the deletion itself is recorded — but \
                the content cannot be recovered or verified again.

                Anything you exported earlier still contains it; this does not reach exports or \
                backups.
                """)
        }
    }

    private func display(_ text: String) -> String { text.isEmpty ? "(empty)" : text }
}
