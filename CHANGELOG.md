# Changelog

## 0.1.0

- Start `is_airlock`: `RecordedAirlock<R>`, an `Airlock<R>` whose record is an
  `is_journal` journal, and `witness`, which records an arrival exactly as
  it came, before anything reads it. Nick later ruled that witnessing is
  entirely this package's job — `is_airlock_api` will define no `Witnessed`
  type at all, for arrivals or prompts.
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
  is this package's job. `PromptTap.prompt`/`.reply` read a record back by
  its own id, so a sender never needs a second handle on the journal.
  `pass` is `JourneyPathId`, not a bare `String`.
- `RecordedAirlock<R, P>`: follows `is_airlock_api` 0.2.0's move to
  `Airlock<R, P>`, where `P` is the host's place-in-a-turn type and every
  `Entry<P>` carries one. `decide`/`narrows` are unaffected; `record` takes
  `Entry<P>`, and the journal line for each entry now names its place.
- Fix `is_effects`'s pubspec comment: it has never been published to
  pub.dev at all (not merely an outdated 0.1.0), so the hosted entry plus
  `dependency_overrides` pairing is structural, not optional — a consumer
  of this package over git must copy the override itself.
