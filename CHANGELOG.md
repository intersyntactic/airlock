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
  Superseded a few commits later by `Entry<R, P>` — see below.
- Fix `is_effects`'s pubspec comment: at the time, it had never been
  published to pub.dev at all (not merely an outdated 0.1.0), so the
  hosted entry plus `dependency_overrides` pairing was structural, not
  optional. `is_effects` has since published 0.1.0 for real; the
  override is gone and this is a plain hosted dependency now.
- `bin/airlock_service.dart`: runs `witness` as its own process over a
  Unix socket, for a host (the Teams relay) that can't hold a journal
  itself without losing `dart compile exe`. One request, one response,
  one connection; never a success on a failure. `SIGTERM`/`SIGINT` stop
  new connections, wait for in-flight ones, then close the journal —
  never the other way around.
- Bump `is_journal` to 0.3.0 — hosted; briefly git-pinned because
  pub.dev's package listing lags a fresh publish by about ten minutes,
  which read as "not published" until it caught up — which can run
  compiled given its code hash at build time. `WitnessService` answers an
  `ObjectNotKept` failure (the entry went in, its object did not)
  distinctly — `{"error": ..., "entry": ...}` — so a client knows not to
  retry the same request, which would record the arrival twice.
- Follow `is_airlock_api` 0.2.0's move to `Entry<R, P>` (every kind now
  carries both the rules type and the place type, not just `P`) and
  `PathInRepo` → `RelativePath` (now `is_effects`'s own, published).
  `record` takes `Entry<R, P>`; the journal line's switch over `Entry`
  is exhaustive again, with no throwing fallback case — the earlier
  `Entry<P>` shape couldn't bind `Narrowed`'s independent `R`, so Dart
  could never prove the switch covered every kind.
- `Reach` gains a fourth case, `Sends(origin, signIn)` — posting to a
  chat, an issue tracker or any site out of the home, decided like any
  other effect. The journal line now covers it: `sends <origin> as
  <sign-in>` (or `as no sign-in`).
