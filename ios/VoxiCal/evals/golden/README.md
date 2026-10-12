# Golden Eval Set

The **golden set** is the canonical, minimal collection of eval suites that
every change to VoxiCal's agent must keep passing. Each suite exercises one
workflow and maps directly to the code-based graders defined in
`tests/EvalCore.swift`.

| Suite | File | Covers |
|-------|------|--------|
| Read & Retrieve | `read_retrieve.yaml` | Greeting (no tool call), meeting lookup, hallucination guard, broad schedule query, empty day |
| Create Event | `create_event.yaml` | Happy path, missing-details clarification, conflict detection, all-day birthday, movie default duration |
| Update & Reschedule | `update_event.yaml` | Fetch-then-update, update-not-create, hiding internals |
| Voice Output Guardrails | `voice_output.yaml` | Plain-text TTS output, no ID leaks, no false success claims, non-calendar chatter |

These mirror the nine `goldenTestCases` in `tests/EvalCore.swift` and extend
them with the voice-output guardrails that make responses safe to read aloud.

## Format

Each scenario uses the shared YAML schema:

```yaml
- id: <stable-id>
  name: <human-readable description>
  category: <grouping label>
  user: <single-turn message>        # or `turns:` for multi-turn
  seed_events: []                    # events pre-loaded into MockCalendarService
  expected:
    workflow: <expected behavior>
  graders:                           # names of graders in EvalCore.swift
    - toolCalledGrader
    - noUUIDInResponseGrader
```

The grader names reference functions in `tests/EvalCore.swift`, so the YAML
stays in sync with the executable Swift suite.
