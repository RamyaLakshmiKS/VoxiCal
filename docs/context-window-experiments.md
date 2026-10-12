# Context Window Engineering in VoxiCal

This document is the deep-dive companion to the README's section
*"The Biggest Engineering Challenge: Managing the LLM Context Window."* It
records the problem, the techniques that are actually implemented in the code,
the reasoning behind each one, the trade-offs that remain, and how to reproduce
the behavior.

> **Honesty note.** VoxiCal runs entirely on Apple's on-device foundation model
> ([`SystemLanguageModel.default`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)).
> There is **no token-billing API** and the repository does **not** contain a
> recorded benchmark harness that logs per-request token counts. Every number
> below that is marked *(design estimate)* comes from the token-budget
> arithmetic encoded directly in the source comments, not from a measurement
> log. Claims about **behavior** (which tools load, which prompt sections load,
> what gets filtered) are verifiable by reading the cited code and by running
> the eval suite. Approaches that were considered but not built are labelled
> **Proposed**.

---

## 1. The constraint

Apple's on-device model exposes a **4,096-token context window** — this budget
must simultaneously hold the system instructions, the tool schemas, the
conversation history, every tool result, and leave room for the model's reply.
The window size is documented inline in the code:

```swift
// Archive when estimated token usage approaches the 4,096-token context window.
// ~4 chars per token; reserve ~1,100 tokens for the upcoming response + tool calls.
if estimatedSessionTokens() > 3_000 {
```
— [`VoxiCalAgent.sendMessage`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

Unlike a cloud model with a 128K+ window, there is no headroom to "just keep
everything." A calendar assistant is tool-heavy and multi-turn, so the naive
assembly below overflows quickly.

### What was originally being sent to the model

A single session was created once with:

- **The full system prompt** — every rule for reading, creating, updating, and
  deleting events, plus voice-style rules and transcription-repair rules.
- **All four calendar tool schemas** — `fetch`, `create`, `update`, `delete`,
  each with `@Guide`-annotated argument descriptions.
- **The entire conversation transcript**, growing with every turn.
- **Raw tool output**, including internal event-ID strings.

### Why that failed

| Symptom | Cause |
|---|---|
| Context overflow on long chats | Full transcript + all tool schemas never shrank |
| Event IDs leaking into spoken replies | Raw tool output (with UUIDs) fed straight back to the model |
| Wasted tokens on irrelevant tools | A read query still paid for `create`/`update`/`delete` schemas |
| Date-math mistakes | The model was asked to compute "next Friday" itself |
| Retry loops on empty results | Empty fetches didn't clearly tell the model to stop |

The git history shows this was a sustained, iterative effort rather than a
single fix — see the `context-management` and `context-engineering` branches and
commits such as `feat: Archive context to handle memory window limit`,
`fix: system prompt length, prompt-code alignment & per-intent tool
restriction`, and `feat: add cache to optimize context window`.

---

## 2. The strategy: a hybrid, intent-scoped context budget

Rather than one technique, VoxiCal combines several so that each category of
context (instructions, tools, history, tool output, output headroom) is
controlled independently. The sections below map each technique to the exact
code that implements it.

### 2.1 Intent-scoped instruction composition — *Implemented*

**Hypothesis.** Most of the system prompt is irrelevant to any single turn. A
"what's on my calendar today?" request does not need the create/update/delete
rules.

**How it works.** The instructions are stored as independent string sections
(`introSection`, `fetchSection`, `eventIDSection`, `createSection`,
`updateSection`, …). `buildInstructions(for:)` detects the user's intent and
concatenates **only** the sections that intent needs:

```swift
if intent != .create                                             { parts.append(fetchSection) }
if intent == .delete || intent == .update || intent == .unknown  { parts.append(eventIDSection) }
...
if intent == .create || intent == .unknown                       { parts.append(createSection) }
if intent == .update || intent == .unknown                       { parts.append(updateSection) }
```
— [`VoxiCalAgent.buildInstructions`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

**What it solved.** A read turn no longer carries create/update/delete prose.
**Limitation.** The `.unknown` intent is a safe superset that loads everything,
so ambiguous phrasing forfeits the savings.

### 2.2 Intent-scoped tool subsets — *Implemented*

**Hypothesis.** Tool *schemas* are a large, fixed context cost. Loading all four
calendar tools on every turn is wasteful when only one is reachable.

**How it works.** `buildSession(for:)` loads a different tool set per intent:

```swift
switch intent {
case .read:    tools = [fetch, search]
case .create:  tools = [create, search]
case .delete:  tools = [fetch, delete, search]
case .update:  tools = [fetch, update, search]
case .unknown: tools = [fetch, delete, create, update, search]
}
```
— [`VoxiCalAgent.buildSession`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

The eval harness documents the intended saving in a comment:

```swift
// Read-only scenarios only need the fetch tool — omitting Create/Update saves ~800 tokens
// of tool schema context, preventing context window overflow on longer read queries.
```
— [`EvalRunner.runScenario`](../ios/VoxiCal/tests/EvalCore.swift)

**What it solved.** Reclaims schema tokens for history and output on the turns
that need them most (long read queries).
**Limitation.** Switching intent **rebuilds the session**, which resets the
model's in-session transcript — mitigated by §2.7 (recent-history re-injection).
The *(design estimate)* of ~800 tokens is the author's annotation, not a logged
measurement.

### 2.3 Pre-computed date anchors — *Implemented*

**Hypothesis.** Date arithmetic is both error-prone for a 3B model and a
recurring token sink if the model reasons it out in-band every turn.

**How it works.** Dates are computed in Swift once and injected as a compact
prefix the model treats as ground truth:

```swift
let datePrefix = """
    Today is \(verbose). Current time: \(isoCurrentTime). \
    YYYY-MM-DD dates — use these EXACTLY: \
    today=\(isoToday), tomorrow=\(isoTomorrow), yesterday=\(isoYesterday). \
    Weekdays this week: Mon=\(isoThisMonday), ... \
    This week: ... Next week: ... This month: ...
    For update/delete fetches: startISO=\(isoToday) endISO=\(iso14DaysLater).
    """
```
— [`VoxiCalAgent.buildInstructions`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

**What it solved.** The model substitutes a literal date instead of computing
it, which both shrinks reasoning tokens and improves correctness.
**Limitation.** Anchors are frozen at session-build time, so they go stale at
midnight — handled by §2.8.

### 2.4 Tool-output filtering — *Implemented*

**Hypothesis.** Raw tool responses are the least controlled, highest-variance
source of context. A busy calendar could return dozens of events plus internal
IDs, blowing the budget and leaking IDs into speech.

**How it works** ([`FetchCalendarEventsTool`](../ios/VoxiCal/VoxiCal/CalendarTool.swift)):

1. **Hard cap** — at most 25 events are serialized; the rest are summarized with
   a "narrow your date range" notice (`let maxEvents = 25`).
2. **Human/internal split** — user-facing lines are separated from an
   `[INTERNAL — DO NOT SHOW TO USER]` block that carries event IDs for
   follow-up update/delete calls, so UUIDs never enter the spoken reply.
3. **Terminal empty-result message** — an empty fetch returns an explicit
   "do not search again" string to stop retry loops.
4. **Generic-filter normalization** — words like `meeting`, `event`, `*`, `all`
   are mapped to "no filter" so the model doesn't over-constrain a query.

**What it solved.** Bounds the single most unpredictable context contributor and
removes the ID-leak failure mode.
**Limitation.** The 25-event cap means very broad queries ("everything this
year") are intentionally truncated rather than paginated.

### 2.5 Proactive token budgeting + archival — *Implemented*

**Hypothesis.** It is cheaper to act *before* the window overflows than to
recover from a thrown error.

**How it works.** Before each turn, VoxiCal estimates usage at ~4 chars/token
and, if the estimate crosses 3,000 of the 4,096 tokens (reserving ~1,100 for the
response + tool calls), it writes the transcript to disk and drops the session:

```swift
private func estimatedSessionTokens() -> Int {
    let instructionChars = VoxiCalAgent.buildInstructions(for: currentIntent).count
    let messageChars = messages.reduce(0) { $0 + $1.text.count }
    return (instructionChars + messageChars) / 4
}
```
```swift
if estimatedSessionTokens() > 3_000 {
    try? archive.save(messages)
    session = nil   // force a fresh session; messages UI remains unchanged
}
```
— [`VoxiCalAgent`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

**What it solved.** Turns a hard failure into a silent, pre-emptive reset. The
on-screen chat is never trimmed — only the model's session is.
**Limitation.** The 4-chars-per-token heuristic is approximate; it is a
deliberately conservative proxy, not a true tokenizer count.

### 2.6 Reactive overflow recovery — *Implemented*

**Hypothesis.** The estimate can still be wrong, so there must be a safety net.

**How it works.** If `respond` throws an error whose description mentions
`context` / `token` / `exceeded`, VoxiCal archives, rebuilds a fresh session,
and silently retries the same user message once:

```swift
if desc.contains("context") || desc.contains("token") || desc.contains("exceeded") {
    try? archive.save(messages)
    buildSession(for: currentIntent, recentHistory: nil)
    if let rebuiltSession = self.session,
       let response = try? await rebuiltSession.respond(to: trimmed) { ... }
}
```
— [`VoxiCalAgent.sendMessage`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

**What it solved.** Guarantees a user-visible answer even if the proactive
budget misjudged.
**Limitation.** The retry starts from a clean session (no recent history) to
maximize headroom, trading some conversational continuity for reliability.

### 2.7 Retrieval-based memory (archive + search tool) — *Implemented*

**Hypothesis.** History should live on disk and be *retrieved on demand*, not
permanently resident in the window. This is a lightweight RAG over the
conversation itself.

**How it works.** [`ConversationArchive`](../ios/VoxiCal/VoxiCal/ConversationArchive.swift)
writes each session's transcript to Markdown under
`Documents/VoxiCalArchives/<sessionID>/`. The model can then pull back only the
relevant slice through a tool:

```swift
struct SearchArchiveTool: Tool {
    let name = "searchConversationHistory"
    let description = "Search archived conversation history for something discussed earlier in this session."
    func call(arguments: Arguments) async throws -> String {
        archive.search(query: arguments.query)  // returns ±a few lines around each keyword hit
    }
}
```
— [`SearchArchiveTool`](../ios/VoxiCal/VoxiCal/SearchArchiveTool.swift)

**What it solved.** Older turns stop consuming the window yet remain reachable:
after a budget-triggered reset (§2.5), the facts are not lost — the model can
search for them.
**Limitation.** `search` is a keyword/substring match, not semantic retrieval,
so a paraphrased query may miss a relevant archived passage.

### 2.8 Sliding recent-history window + daily rebuild — *Implemented*

**How it works.** When a session is rebuilt (intent change or budget reset),
only the **last four messages** are re-injected as a compact preamble, and a
date rollover forces a clean rebuild so anchors never go stale:

```swift
private func recentHistoryContext() -> String {
    let recent = messages.suffix(4)
    ...
    return "[Recent conversation:]\n" + lines.joined(separator: "\n")
}
```
— [`VoxiCalAgent.recentHistoryContext`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

**What it solved.** Preserves immediate conversational continuity across a
rebuild at a bounded, predictable cost (4 messages), while retrieval (§2.7)
covers anything older.
**Limitation.** Exactly four messages is a fixed heuristic; a relevant message
five turns back is only recoverable through the archive search tool.

### 2.9 Deterministic client-side fast-path — *Implemented*

**Hypothesis.** The most context-expensive flow is a multi-turn *create*
clarification ("what time?" → "how long?" → "where?"), each round-trip spending
tokens. If required fields can be gathered deterministically in Swift, the LLM
is only invoked once with a compact, complete prompt.

**How it works.** Regex extractors (`extractedTitle`, `extractedDate`,
`extractedTime`, `extractedDurationMinutes`, `extractedLocation`) and
`clarificationForAmbiguousCreateRequest` collect create fields on-device. Only
when everything is present does `synthesizeCreatePrompt` build a one-line prompt
for the model:

```swift
private func synthesizeCreatePrompt(from draft: CreateCalendarEventTool.Arguments) -> String {
    var parts = ["Create an event:"]
    parts.append("title '\(draft.title)'")
    parts.append("starting \(draft.startISO)")
    if let mins = draft.durationMinutes { parts.append("for \(mins) minutes") }
    ...
}
```
— [`VoxiCalAgent`](../ios/VoxiCal/VoxiCal/VoxiCalAgent.swift)

**What it solved.** Clarification loops happen without model calls, so the token
budget is spent on the single actionable turn.
**Limitation.** The extractors are English- and pattern-specific; unusual
phrasing falls back to the full LLM path (which is the intended safety net).

---

## 3. Approaches considered but **not** implemented (*Proposed*)

To keep the record honest, these were evaluated conceptually and **not** built.
They are future directions, not findings.

| Technique | Status | Why not (yet) |
|---|---|---|
| LLM conversation **summarization** | Proposed | Archival + retrieval (§2.7) already frees the window without the extra model call a summarizer would cost on a 4K budget. |
| **Semantic** archive retrieval (embeddings) | Proposed | Current `search` is keyword-based; on-device embeddings would improve recall but add model/storage complexity. |
| True tokenizer-based budgeting | Proposed | The 4-chars/token heuristic is a cheap proxy; a real tokenizer would tighten §2.5 but isn't exposed conveniently on-device. |
| Streaming/structured tool-output pagination | Proposed | The 25-event cap is a simpler bound than cursor-based paging for a personal calendar. |

---

## 4. Reproducing the behavior

The context-management logic is exercised by the eval suite. These do not print
token counts (none are logged), but they verify the *observable* consequences:
no ID leaks, no false success claims, correct tool selection, and graceful
empty-result handling.

```bash
xcodebuild test \
  -project ios/VoxiCal/VoxiCal.xcodeproj \
  -scheme VoxiCal \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:VoxiCalTests
```

Relevant graders in [`tests/EvalCore.swift`](../ios/VoxiCal/tests/EvalCore.swift):

- `noUUIDInResponseGrader` / `noEventIDInResponseGrader` — proves the
  human/internal output split (§2.4) keeps IDs out of replies.
- `noFalseSuccessClaimGrader` — proves success-reporting discipline.
- `nothingScheduledNotDontKnowGrader` — proves the terminal empty-result path.
- Tool-selection graders — exercise the intent-scoped sessions (§2.1–§2.2).

> **Reproducibility caveat.** The evals call the real on-device model, whose
> decoding is non-deterministic by default (random sampling). The runner
> re-attempts a scenario up to three times to absorb that variance
> (`maxAttemptsPerScenario`). For a deterministic run, Apple's
> `GenerationOptions` supports greedy sampling — not currently wired in.

---

## 5. Summary

VoxiCal does not treat context management as "trim the prompt." It budgets each
context category separately: **instructions** and **tool schemas** scale with
intent; **tool output** is capped and ID-filtered; **history** lives on disk and
is retrieved on demand with a small recent-message window kept hot; and an
**output reserve** is protected by both a proactive estimate and a reactive
recovery path. The result keeps a tool-heavy, multi-turn assistant inside a
4,096-token window without silently losing the user's facts.
