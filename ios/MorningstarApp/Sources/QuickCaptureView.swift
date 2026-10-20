import SwiftUI
import MorningstarKit

/// The fast path, inside the app: one field, one button, no journey.
///
/// Dictation needs no code — the system keyboard's microphone runs on-device
/// and nothing leaves the phone, which is the only kind of dictation this
/// instrument could accept.
///
/// Deliberately absent: leakage flags. They belong to a review step, and at
/// event speed there isn't one. Nothing should stand between a person and
/// recording what just happened.
struct QuickCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var committed: Capture?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    if let committed {
                        Text("☯").font(.system(size: 48)).foregroundStyle(Palette.ink)
                        Text("Capture \(String(format: "%03d", committed.sequenceNumber)) committed.")
                            .font(.system(.title3, design: .serif))
                            .foregroundStyle(Palette.ink)
                        Text("Recorded as written, unsorted. You can separate it into "
                             + "observation, experience, and action later — that gets added "
                             + "alongside, and this stays as you took it down.")
                            .font(.footnote).foregroundStyle(Palette.ink.opacity(0.65))
                        Spacer()
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent).tint(Palette.wave)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Say what happened. Don't sort it.")
                            .font(.system(.title3, design: .serif))
                            .foregroundStyle(Palette.ink)
                        Text("However it comes out is fine. Nothing here is checked, "
                             + "corrected, or counted.")
                            .font(.footnote).foregroundStyle(Palette.ink.opacity(0.6))
                        TextEditor(text: $text)
                            .focused($focused)
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(Color.white.opacity(0.6),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(Palette.ink.opacity(0.12)))
                        if let error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Spacer()
                        Button("Record", action: commit)
                            .buttonStyle(.borderedProminent).tint(Palette.wave)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func commit() {
        do {
            let capture = try model.commitQuick(
                text.trimmingCharacters(in: .whitespacesAndNewlines))
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                committed = capture
            }
        } catch {
            self.error = "\(error)"
        }
    }
}
