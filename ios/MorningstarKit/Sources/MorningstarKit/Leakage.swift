/// Gentle, optional layer-leakage detection — port of the rule table in
/// the Python reference (`morningstar/leakage.py`).
///
/// Design constraints, in order: never block submission; never rewrite
/// user text; explain why a phrase may cross layers; accept false
/// positives rather than police natural language. Felt states in the
/// phenomenology channel are deliberately not flagged as diagnoses.

import Foundation

public enum CaptureChannel: String, CaseIterable, Sendable {
    case observation, phenomenology, action
}

public struct LeakageWarning: Equatable, Sendable {
    public let channel: CaptureChannel
    public let matchedText: String
    public let reason: String
    public let suggestion =
        "You can keep it as written, or move it to an interpretation later."
}

struct LeakageRule {
    let pattern: String
    let channels: Set<CaptureChannel>
    let reason: String
}

private let allChannels: Set<CaptureChannel> = [.observation, .phenomenology, .action]

let leakageRules: [LeakageRule] = [
    LeakageRule(
        pattern: #"\bbecause\b"#,
        channels: allChannels,
        reason: "“because” usually introduces a causal explanation, which belongs in the interpretation layer."),
    LeakageRule(
        pattern: #"\b(?:he|she|they|you)\s+(?:want(?:s|ed)?|meant|intend(?:s|ed)?|(?:was|were|is|are)\s+trying|tried\s+to|think(?:s)?|thought)\b"#,
        channels: [.observation, .phenomenology],
        reason: "This looks like a claim about another person's motives or inner state, which can't be directly observed."),
    LeakageRule(
        pattern: #"\b(?:narcissist\w*|sociopath\w*|manipulative|manipulator|toxic|gaslight\w*|avoidant|passive[- ]aggressive)\b"#,
        channels: allChannels,
        reason: "This looks like a personality or diagnostic label rather than an observation or felt experience."),
    LeakageRule(
        pattern: #"\b(?:depress(?:ed|ion)|anxiety\s+disorder|adhd|ocd|bipolar|borderline|ptsd)\b"#,
        channels: [.observation, .action],
        reason: "This looks like a diagnostic term. Diagnoses are interpretations, not observations."),
    LeakageRule(
        pattern: #"\b(?:will\s+never|will\s+always|is\s+going\s+to\s+(?:leave|end|fail)|doomed)\b"#,
        channels: allChannels,
        reason: "This looks like a prediction. Captures record what happened and what was felt, not what will happen."),
    LeakageRule(
        pattern: #"\b(?:should(?:n[’']t|\s+not)?|ought\s+to)\b"#,
        channels: [.observation, .action],
        reason: "“should” often carries a moral evaluation, which belongs in the interpretation layer."),
    LeakageRule(
        pattern: #"\bmade\s+me\b"#,
        channels: [.observation, .phenomenology],
        reason: "“made me” attributes causation. The feeling is evidence; the cause is an interpretation."),
    LeakageRule(
        pattern: #"\b(?:means\s+that|which\s+means|clearly|obviously)\b"#,
        channels: [.observation],
        reason: "This looks like inferred meaning rather than an externally observable fact."),
    LeakageRule(
        pattern: #"\bin\s+order\s+to\b"#,
        channels: [.observation],
        reason: "“in order to” attributes a purpose, which can't be directly observed."),
]

public func checkLeakage(channel: CaptureChannel, text: String) -> [LeakageWarning] {
    var warnings: [LeakageWarning] = []
    for rule in leakageRules where rule.channels.contains(channel) {
        guard let regex = try? NSRegularExpression(
            pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) {
                warnings.append(LeakageWarning(
                    channel: channel, matchedText: String(text[r]), reason: rule.reason))
            }
        }
    }
    return warnings
}

public func checkLeakage(observation: String, phenomenology: String, action: String) -> [LeakageWarning] {
    checkLeakage(channel: .observation, text: observation)
        + checkLeakage(channel: .phenomenology, text: phenomenology)
        + checkLeakage(channel: .action, text: action)
}
