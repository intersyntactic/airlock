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
- `Witness`, holding `witness` and `prompt`, factored out from
  `RecordedAirlock` (which now extends it): needs no rules and decides no
  runs, so a caller with neither — a pipeline sending its own prompts —
  builds one directly instead of inventing a `decide`/`narrows` it
  doesn't have.
- `Witness.prompt`: sends a prompt, records it (masked) before anything
  goes, gathers the reply as it arrives, records that too, and returns
  the reply's own id alongside exactly what it recorded. Replaces an
  earlier `prompting`/`PromptTap`/`ReplyTap` design where a caller drove
  its own HTTP and the airlock only recorded what it was handed — Nick
  ruled that out: the airlock is the only thing that sends, so no caller
  can hold a client of its own. The record format (`model prompt`/`model
  reply`, the link, per-provider `source`, `JourneyPathId` `pass`) is
  unchanged; only who holds the connection moved.
- `prompt` strips the default `Accept-Encoding` it would otherwise send
  and turns `autoUncompress` off on a client it makes for itself, so the
  bytes recorded and returned match the bytes that actually crossed the
  wire — compression only happens when the caller's own headers ask for
  it. Without this, an upstream that compressed its reply would be
  recorded decompressed while its headers still said `gzip`.
- `RecordedAirlock<R, P>`: follows `is_airlock_api` 0.2.0's move to
  `Airlock<R, P>`, where `P` is the host's place-in-a-turn type and every
  `Entry<P>` carries one. `decide`/`narrows` are unaffected; `record` takes
  `Entry<P>`, and the journal line for each entry now names its place.
- Fix `is_effects`'s pubspec comment: it has never been published to
  pub.dev at all (not merely an outdated 0.1.0), so the hosted entry plus
  `dependency_overrides` pairing is structural, not optional — a consumer
  of this package over git must copy the override itself.
