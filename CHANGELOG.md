# Changelog

## 0.1.0

- Start `is_airlock`: `RecordedAirlock<R>`, an `Airlock<R>` whose record is an
  `is_journal` journal, and `witness`, which records an arrival exactly as
  it came, before anything reads it. Shaped to become `Witnessed` once
  `is_airlock_api` 0.3.0 adds one.
- Re-export `is_airlock_api` and `is_effects`: writing `decide` means naming
  `Decision`, `Allow`, `Deny` and `DecidedBy` at least, so a caller of
  `RecordedAirlock` needs them whether or not it depends on those packages
  itself. Without the re-export, a caller would have to repeat this
  package's git pins on both to name them, with the two able to drift
  apart.
- `RecordedAirlock.prompting`: records a prompt before it goes and its
  reply once it ends, naming which prompt it answers, with its status,
  headers and how it ended. A port of `intelligent-reporting`'s `CallTap`
  (now `PromptTap`), moved here since recording what crosses the airlock
  is this package's job.
