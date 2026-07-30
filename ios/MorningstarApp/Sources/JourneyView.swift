import SwiftUI
import MorningstarKit

/// The guided sequential journey — the site's full-screen sections flowing
/// one into the next. Each stage ends by advancing to the next stage's
/// glyph; the header glyph returns to the hub, mirroring the site's
/// glyph-as-return. Transitions are smooth (the site's `scroll-behavior:
/// smooth`, rendered as SwiftUI page slides).
struct JourneyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage
    @State private var committed: Capture?

    init(start: Stage) { _stage = State(initialValue: start) }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.3)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
                    .id(stage)
            }
        }
    }

    private var header: some View {
        HStack {
            // Glyph = return to hub.
            Button { dismiss() } label: {
                Text(stage.glyph).font(.system(size: 34)).foregroundStyle(Palette.ink)
            }
            .accessibilityLabel("Close and return to the hub")
            Spacer()
            HStack(spacing: 10) {
                ForEach(Stage.allCases) { s in
                    Circle()
                        .fill(s.rawValue <= stage.rawValue ? Palette.wave : Palette.ink.opacity(0.2))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            Text(stage.name).font(.callout).foregroundStyle(Palette.ink.opacity(0.5))
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .breath: BreathView(advance: advance)
        case .mind:   MindView(advance: advance)
        case .eye:    EyeView(advance: advance)
        case .play:   PlayView(committed: $committed, finish: finish)
        }
    }

    private func advance() {
        guard let next = stage.next else { return }
        withAnimation(.easeInOut(duration: 0.45)) { stage = next }
    }

    private func finish() {
        model.resetDraft()
        dismiss()
    }
}
