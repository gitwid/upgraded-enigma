"""Gentle, optional layer-leakage detection.

Captures are evidence; interpretation is a later layer. These checks
flag phrases that *may* carry interpretation (causality, motives,
diagnoses, predictions, judgments) into a capture channel.

Design constraints, in order:
  * never block submission
  * never rewrite user text
  * explain why a phrase may cross layers
  * accept false positives rather than police natural language
"""

from __future__ import annotations

import re
from dataclasses import dataclass

CHANNELS = ("observation", "phenomenology", "action")

_MOVE = "You can keep it as written, or move it to an interpretation later."


@dataclass(frozen=True)
class Rule:
    pattern: str
    channels: tuple[str, ...]
    reason: str


@dataclass(frozen=True)
class LeakageWarning:
    channel: str
    matched_text: str
    reason: str
    suggestion: str = _MOVE


RULES: tuple[Rule, ...] = (
    Rule(r"\bbecause\b", CHANNELS,
         "“because” usually introduces a causal explanation, "
         "which belongs in the interpretation layer."),
    Rule(r"\b(?:he|she|they|you)\s+(?:want(?:s|ed)?|meant|intend(?:s|ed)?|"
         r"(?:was|were|is|are)\s+trying|tried\s+to|think(?:s)?|thought)\b",
         ("observation", "phenomenology"),
         "This looks like a claim about another person's motives or "
         "inner state, which can't be directly observed."),
    Rule(r"\b(?:narcissist\w*|sociopath\w*|manipulative|manipulator|toxic|"
         r"gaslight\w*|avoidant|passive[- ]aggressive)\b", CHANNELS,
         "This looks like a personality or diagnostic label rather than "
         "an observation or felt experience."),
    Rule(r"\b(?:depress(?:ed|ion)|anxiety\s+disorder|adhd|ocd|bipolar|"
         r"borderline|ptsd)\b", ("observation", "action"),
         "This looks like a diagnostic term. Diagnoses are "
         "interpretations, not observations."),
    Rule(r"\b(?:will\s+never|will\s+always|is\s+going\s+to\s+(?:leave|end|fail)|"
         r"doomed)\b", CHANNELS,
         "This looks like a prediction. Captures record what happened "
         "and what was felt, not what will happen."),
    Rule(r"\b(?:should(?:n[’']t|\s+not)?|ought\s+to)\b",
         ("observation", "action"),
         "“should” often carries a moral evaluation, which "
         "belongs in the interpretation layer."),
    Rule(r"\bmade\s+me\b", ("observation", "phenomenology"),
         "“made me” attributes causation. The feeling is "
         "evidence; the cause is an interpretation."),
    Rule(r"\b(?:means\s+that|which\s+means|clearly|obviously)\b",
         ("observation",),
         "This looks like inferred meaning rather than an externally "
         "observable fact."),
    Rule(r"\bin\s+order\s+to\b", ("observation",),
         "“in order to” attributes a purpose, which can't be "
         "directly observed."),
)

_COMPILED = [(re.compile(r.pattern, re.IGNORECASE), r) for r in RULES]


def check_text(channel: str, text: str) -> list[LeakageWarning]:
    warnings = []
    for regex, rule in _COMPILED:
        if channel not in rule.channels:
            continue
        for match in regex.finditer(text):
            warnings.append(LeakageWarning(
                channel=channel,
                matched_text=match.group(0),
                reason=rule.reason,
            ))
    return warnings


def check_capture(observation: str, phenomenology: str, action: str) -> list[LeakageWarning]:
    return (check_text("observation", observation)
            + check_text("phenomenology", phenomenology)
            + check_text("action", action))
