import SwiftUI
import MorningstarKit

/// The glyph portal — the site's frontpage `<ul>` of four icons. Tapping a
/// glyph enters the capture journey at that stage (consequence-free jumps,
/// as the site's frontpage links did). Names sit quietly beneath each glyph:
/// the honest touch translation of the site's hover-reveal tooltips.
struct HubView: View {
    @Environment(AppModel.self) private var model
    @State private var journeyStart: Stage?
    @State private var showArchive = false
    @State private var showAudit = false

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(spacing: 40) {
                Text("Morningstar")
                    .font(.system(.largeTitle, design: .serif))
                    .foregroundStyle(Palette.ink)

                Text("An observational instrument. It records; it does not judge.")
                    .font(.footnote)
                    .foregroundStyle(Palette.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                HStack(spacing: 18) {
                    ForEach(Stage.allCases) { stage in
                        GlyphButton(stage: stage) { journeyStart = stage }
                    }
                }
                .glassCard()

                if let line = model.reentryLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(Palette.ink.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer().frame(height: 8)

                HStack(spacing: 28) {
                    Button("Archive") { showArchive = true }
                    Button("Audit") { showAudit = true }
                }
                .font(.callout)
                .foregroundStyle(Palette.wave)
            }
            .padding()
        }
        .fullScreenCover(item: $journeyStart) { start in
            JourneyView(start: start)
                .environment(model)
        }
        .sheet(isPresented: $showArchive) {
            ArchiveView().environment(model)
        }
        .sheet(isPresented: $showAudit) {
            AuditView().environment(model)
        }
    }
}

struct GlyphButton: View {
    let stage: Stage
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(stage.glyph)
                    .font(.system(size: 52))
                    .foregroundStyle(Palette.ink)
                    .scaleEffect(pressed ? 0.88 : 1)
                Text(stage.name)
                    .font(.caption2)
                    .foregroundStyle(Palette.ink.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stage.name) — \(stage.role)")
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.easeOut(duration: 0.1)) { pressed = true } }
            .onEnded { _ in withAnimation(.easeOut(duration: 0.15)) { pressed = false } })
    }
}
