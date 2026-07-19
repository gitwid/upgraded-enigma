import SwiftUI

/// The four stages of the capture liturgy, carried over verbatim from the
/// Digital Mindfulness site (index.html): the glyphs and names are the
/// originals; their meaning is re-skinned onto Morningstar's capture flow.
/// Glyph = identity and return, exactly as each site section opened with
/// its own glyph linking back to the hub.
enum Stage: Int, CaseIterable, Identifiable {
    case breath, mind, eye, play
    var id: Int { rawValue }

    var glyph: String {
        switch self {
        case .breath: return "☥"   // U+2625, site &#9765;
        case .mind:   return "☁"   // U+2601, site &#9729;
        case .eye:    return "☉"   // U+2609, site &#9737;
        case .play:   return "☯"   // U+262F, site &#9775;
        }
    }

    var name: String {
        switch self {
        case .breath: return "Breath"
        case .mind:   return "Mind"
        case .eye:    return "Eye"
        case .play:   return "Play"
        }
    }

    /// What the stage does in the instrument (the re-skin).
    var role: String {
        switch self {
        case .breath: return "Arrive"
        case .mind:   return "Observe"
        case .eye:    return "Review"
        case .play:   return "Commit"
        }
    }

    var next: Stage? { Stage(rawValue: rawValue + 1) }
}

enum Palette {
    // Drawn from the site's warm-paper / wave-blue draft, deliberately quiet.
    static let paper = Color(red: 0.93, green: 0.90, blue: 0.82)
    static let ink = Color(red: 0.13, green: 0.13, blue: 0.13)
    static let wave = Color(red: 0.0, green: 0.55, blue: 1.0)
    static let waveSoft = Color(red: 0.75, green: 0.96, blue: 0.96)
}

/// Glass chrome, paper evidence: controls float on translucent material;
/// evidence text stays plain and inert (see DESIGN.md).
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}
