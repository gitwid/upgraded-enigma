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
                        "No captures yet",
                        systemImage: "circle.dotted",
                        description: Text("Begin a capture from the hub."))
                } else {
                    List(model.captures.reversed(), id: \.id) { capture in
                        NavigationLink {
                            CaptureDetailView(capture: capture)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Capture \(String(format: "%03d", capture.sequenceNumber))")
                                    .font(.headline)
                                Text(firstLine(capture))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    ShareLink(item: textExport()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(model.captures.isEmpty)
                }
            }
        }
    }

    private func firstLine(_ c: Capture) -> String {
        let source = [c.observation, c.phenomenology, c.action].first { !$0.isEmpty } ?? ""
        return source.split(separator: "\n").first.map(String.init) ?? "(empty)"
    }

    private func textExport() -> String {
        var out = ["MORNINGSTAR ARCHIVE", "app version: \(Morningstar.appVersion)", ""]
        for c in model.captures {
            out.append("MORNINGSTAR — capture \(String(format: "%03d", c.sequenceNumber))")
            out.append("schema: v\(c.schemaVersion)  protocol: v\(c.protocolVersion)")
            out.append("recorded: \(c.recordedAt ?? c.createdAt + " (machine timestamp)")")
            out.append("committed: \(c.committedAt)")
            out.append("source: \(c.source ?? "not stated")")
            out.append("\nOBSERVATION\n-----------\n\(c.observation.isEmpty ? "(empty)" : c.observation)")
            out.append("\nPHENOMENOLOGY\n-------------\n\(c.phenomenology.isEmpty ? "(empty)" : c.phenomenology)")
            out.append("\nACTION\n------\n\(c.action.isEmpty ? "(empty)" : c.action)")
            for a in model.annotations(for: c) {
                out.append("\n[\(a.type)] \(a.createdAt)\n\(a.body)")
            }
            out.append("\nPROVENANCE\n----------\nid: \(c.id)\nintegrity hash: \(c.integrityHash)\nprevious hash: \(c.previousHash)")
            out.append("\n" + String(repeating: "=", count: 60) + "\n")
        }
        return out.joined(separator: "\n")
    }
}

struct CaptureDetailView: View {
    @Environment(AppModel.self) private var model
    let capture: Capture
    @State private var annotationBody = ""
    @State private var annotationType = "note"

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
                    ForEach(annotations, id: \.id) { a in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("[\(a.type)] \(a.createdAt)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(a.body)
                        }
                    }
                }
                Picker("Kind", selection: $annotationType) {
                    Text("note").tag("note")
                    Text("correction").tag("correction")
                    Text("context").tag("context")
                }
                TextField("Add an annotation", text: $annotationBody, axis: .vertical)
                    .lineLimit(2...5)
                Button("Add annotation") { addAnnotation() }
                    .disabled(annotationBody.isEmpty)
            }

            Section("Provenance") {
                LabeledContent("committed", value: capture.committedAt)
                LabeledContent("protocol", value: capture.protocolVersion)
                LabeledContent("schema", value: capture.schemaVersion)
                Text("integrity: \(capture.integrityHash)")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .navigationTitle("Capture \(String(format: "%03d", capture.sequenceNumber))")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func display(_ s: String) -> String { s.isEmpty ? "(empty)" : s }

    private func addAnnotation() {
        model.annotate(capture, type: annotationType, body: annotationBody)
        annotationBody = ""
    }
}
