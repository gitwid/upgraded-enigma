import SwiftUI
import MorningstarKit

// MARK: - Breath — Arrive (re-entry grounding)

/// The site's Breath: "find the right rhythm... a space for your own self."
/// Here it grounds the returning operator (Defender's restore-the-world-
/// before-handing-back-control, Experiment 001) with a slow breathing pulse
/// and the non-interpretive re-entry line. It reads nothing into the gap.
struct BreathView: View {
    @Environment(AppModel.self) private var model
    let advance: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Circle()
                .fill(Palette.waveSoft)
                .frame(width: expanded ? 180 : 110, height: expanded ? 180 : 110)
                .overlay(Circle().stroke(Palette.wave.opacity(0.4), lineWidth: 2))
                .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: expanded)
                .onAppear { expanded = true }
            Text("Arrive. One slow breath before you record.")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            if let line = model.reentryLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            AdvanceButton(title: "Begin", to: .mind, action: advance)
        }
        .padding()
    }
}

// MARK: - Mind — Observe (the three channels + ephemeral wander)

/// The site's Mind: "start writing your thoughts... there is no purpose to
/// this." We keep that purposeless wander pane (Refresh erases it, it is
/// NEVER saved) beside the three evidence channels. Interpretation is not
/// invited here — that is a separate, later layer.
struct MindView: View {
    @Environment(AppModel.self) private var model
    let advance: () -> Void
    @State private var showWander = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                channel("What happened?",
                        "Externally observable facts — times, messages, events. Verbatim quotes welcome.",
                        text: $model.observation)
                channel("What did you experience?",
                        "Immediate feelings and sensations, in your own words.",
                        text: $model.phenomenology)
                channel("What did you do?",
                        "Behavior actually performed. No justification needed.",
                        text: $model.action)

                DisclosureGroup("Optional: when, source, recall latency") {
                    VStack(spacing: 12) {
                        field("When did this happen?", text: $model.recordedAt)
                        field("Source", text: $model.source)
                        field("How long after the events are you writing this?",
                              text: $model.recallLatency)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
                .tint(Palette.wave)

                DisclosureGroup("A space to let your mind wander", isExpanded: $showWander) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No purpose to this. It is never saved.")
                            .font(.caption).foregroundStyle(Palette.ink.opacity(0.5))
                        TextEditor(text: $model.wander)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        Button("Refresh") { model.wander = "" }
                            .font(.caption)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
                .tint(Palette.wave)

                AdvanceButton(title: "Review", to: .eye, action: advance)
                    .padding(.top, 8)
            }
            .padding()
        }
    }

    private func channel(_ title: String, _ hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(.headline, design: .serif)).foregroundStyle(Palette.ink)
            Text(hint).font(.caption).foregroundStyle(Palette.ink.opacity(0.55))
            TextEditor(text: text)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.ink.opacity(0.12)))
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.ink.opacity(0.6))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Eye — Review (leakage chips; every path forward)

/// The site's Eye: "follow the patterns that please you... always choose the
/// one that feels natural." Here you review the draft; gentle leakage chips
/// flag possible layer crossings but never block. Every choice advances —
/// consequence-free, as the site's grid always moved you onward.
struct EyeView: View {
    @Environment(AppModel.self) private var model
    let advance: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Review before committing")
                    .font(.system(.title3, design: .serif)).foregroundStyle(Palette.ink)
                Text("Once committed, this becomes part of the permanent record. Later thoughts can be added as annotations — the original will not change.")
                    .font(.footnote).foregroundStyle(Palette.ink.opacity(0.6))

                review("Observation", model.observation)
                review("Phenomenology", model.phenomenology)
                review("Action", model.action)

                let warnings = model.leakageWarnings()
                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Possible layer leakage")
                            .font(.headline).foregroundStyle(Palette.ink)
                        Text("Gentle flags, not corrections. You can commit exactly what you wrote.")
                            .font(.caption).foregroundStyle(Palette.ink.opacity(0.55))
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                            LeakageChip(warning: w)
                        }
                    }
                    .glassCard()
                }

                AdvanceButton(title: "Continue to commit", to: .play, action: advance)
                    .padding(.top, 4)
            }
            .padding()
        }
    }

    private func review(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            Text(body.isEmpty ? "(empty)" : body)
                .font(.body)
                .foregroundStyle(body.isEmpty ? Palette.ink.opacity(0.4) : Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LeakageChip: View {
    let warning: LeakageWarning
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In \(warning.channel.rawValue), “\(warning.matchedText)”")
                .font(.subheadline).foregroundStyle(Palette.ink)
            Text(warning.reason).font(.caption).foregroundStyle(Palette.ink.opacity(0.7))
            Text(warning.suggestion).font(.caption2).foregroundStyle(Palette.ink.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Play — Commit (haptic settle, then release)

/// The site's Play: "you did it... enjoy the harmonies... then continue your
/// day, refreshed." Here the arrival is the commit: the capture settles into
/// the ledger with a haptic, immutable from that instant. Then it releases
/// you back to the hub.
struct PlayView: View {
    @Environment(AppModel.self) private var model
    @Binding var committed: Capture?
    let finish: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            if let capture = committed {
                Text("☯").font(.system(size: 64)).foregroundStyle(Palette.ink)
                Text("Capture \(String(format: "%03d", capture.sequenceNumber)) committed.")
                    .font(.system(.title3, design: .serif)).foregroundStyle(Palette.ink)
                Text("It is part of the record now. Anything you add later will be an annotation.")
                    .font(.footnote).foregroundStyle(Palette.ink.opacity(0.6))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Spacer()
                Button("Done", action: finish)
                    .buttonStyle(.borderedProminent).tint(Palette.wave)
            } else {
                Text("☯").font(.system(size: 64)).foregroundStyle(Palette.ink.opacity(0.5))
                Text("Ready to commit").font(.system(.title3, design: .serif))
                    .foregroundStyle(Palette.ink)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Commit capture", action: commit)
                    .buttonStyle(.borderedProminent).tint(Palette.wave)
            }
        }
        .padding()
    }

    private func commit() {
        do {
            let capture = try model.commit()
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { committed = capture }
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: - shared advance button

struct AdvanceButton: View {
    let title: String
    let to: Stage
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Text(to.glyph)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.wave)
        .controlSize(.large)
    }
}
