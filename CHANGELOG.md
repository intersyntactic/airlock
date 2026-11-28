# Changelog

## 0.7.0

Drops `is_effects` entirely, following its dissolution into
`is_outcome_vocabulary`, `is_relative_path_vocabulary`,
`is_file_request_vocabulary`, `is_program_request_vocabulary` and
`is_web_request_vocabulary`. `CarriesOutActions` is gone: `Trajectory`
now takes a `Drivers` record (`files`, `programs`, `web`, `model`)
naming each driver's slot, so two drivers of the same kind can no
longer both be given. `Underway`'s `Progress` becomes the sealed
`DriverProgress` (`ProgramPrinted`/`ModelReplyArriving`), since the
program driver and model driver report different piece types.

`is_airlock_api` bumps to ^0.26.0 (renames its `ModelCall` to
`ModelCallNamingRequestEntry`, dodging the clash with
`is_model_vocabulary`'s own `ModelCall`), `is_flight_rules` to
^0.12.0, `is_model_vocabulary` to ^0.5.0, `is_sign_in_vocabulary` to
^0.1.2, and `is_web_request_vocabulary` to ^0.1.1 (`ProposedRequest`
now throws `ArgumentError` on two header names that fold to the same
one; this repo's own `avoid_catching_errors`/
`avoid_catches_without_on_clauses` rules forbid catching it, so the
existing driver-threw path in `Trajectory._consider` — write
`StoppedPartway`, then rethrow — handles it instead of a caught
refusal).

## 0.6.0

`Trajectory`, `DecidesActionsAndWritesToTheLogbook` and `Underway` move
here from `is_airlock_api` (0.21.0/0.22.0, "the contract holds types and
their JSON only"): deciding and carrying an action out, over this
package's own drivers, was never the contract's job. `is_airlock_api`
keeps `CarriesOutEachProgram`, the interface `Trajectory` now implements
one dispatcher of per decided action — bumped to ^0.22.0, with
`is_effects` ^0.17.0, `is_flight_rules` ^0.9.0. Every type `is_effects`
no longer re-exports (`ModelReply`, `SignIn`, `Origin`/`WebPath`/
`PathPrefix`/`AddressPrefix`) is now a direct dependency on its own
vocabulary package.

The reply arm: `runAirlockService` and `Trajectory` take `slackReplies`
and `webAddressReplies` writers (`is_reply_requests_api` ^0.2.0); a
`RepliesToOwnConversation` reach is granted through
`WhatMayLeaveThisMachine.signInForReply`, to the trajectory's own
`ReplyEndpoint` (`is_conversation_reply_vocabulary` ^0.1.0, no longer
narrowed to a web address before `GrantsReaches` sees it). Teams is
wired into `bin/airlock_service.dart` (`is_teams_module`, pinned to the
`teams_module` repo's `v0.0.14` tag — pure, no secrets, no new env
vars); Slack's writer waits on `is_slack_module` publishing.

## 0.2.1

- `AIRLOCK_MODEL_DRIVER_SOCKETS`'s JSON map now carries each sign-in's
  model driver as `{"socket": ..., "user": ...}` in one entry, rather
  than a bare socket path. `RoutesModelCallsBySignIn` checks each
  driver's `user` the same way `AIRLOCK_WEB_DRIVER_USER` already
  checks the web driver — against the kernel's own report of who
  connects, never derived from the socket file. Fixes a regression
  0.2.0 shipped with: the live `61e8d64` unit already checked its one
  model driver's user, and moving to routing-by-sign-in (0.2.0) dropped
  that check entirely, with nothing replacing it (Nick's ruling, 22
  Nov: a release must not check less than what is already live).

## 0.2.0

First tagged release — the version catches up to everything shipped
since the live deploy at `61e8d64`, so infra has a tag to deploy
against. Every environment variable change below is what distinguishes
a deploy of this tag from the live `61e8d64` unit.

- Driver release identity: `bin/airlock_service.dart` now requires
  `AIRLOCK_WEB_DRIVER_USER` (the web driver's own process user, by name
  or numeric uid), checked against the kernel's own report of who
  connects (`is_unix_socket_user_check`), not derived from the socket
  file. `AIRLOCK_WEB_DRIVER_RELEASE` is new and optional: an exact
  `<sha>-<digest>` release id the web driver's socket is expected to be
  running; unset means no release is checked, only its user.
- Route model calls by sign-in: `AIRLOCK_MODEL_DRIVER_SOCKET` (one
  socket) is replaced by `AIRLOCK_MODEL_DRIVER_SOCKETS` (a JSON map
  file's path, sign-in name -> that sign-in's model driver's socket —
  the shape 0.2.1 corrects, see above). `RoutesModelCallsBySignIn`
  dispatches each call to whichever driver its sign-in names, refusing
  a sign-in the map holds none for.
- `RecordedAirlock` renamed to `Airlock`; `record` vocabulary renamed to
  `logbook`/`entry` throughout, matching `is_airlock_api`'s own move.
  `AIRLOCK_RECORD_SOCKET`/`AIRLOCK_RECORD_READ_SOCKET` are renamed to
  `AIRLOCK_LOGBOOK_SOCKET`/`AIRLOCK_LOGBOOK_READ_SOCKET`; the old names
  are still accepted as a fallback until infra's migration window has
  run.

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
- Bump `is_journal` again, to 0.4.0: its code hash now covers
  `is_content_id`'s resolved source too, not just `is_journal`'s own, so
  every build's hash changed from 0.3.0's. Verified end to end again —
  compiled, ran, witnessed a real request, `SIGTERM`'d, exited clean —
  with the resulting `-Dis_journal.code=...` matching journal-0f's
  quoted hash exactly.
- `PromptRecord.headers` is `MaskedHeaders`, not a bare `Map<String,
  String>`: the only way to make one is `MaskedHeaders.of`, which calls
  `masked` itself, so a `PromptRecord` can hold a credential only by a
  caller bypassing the type altogether, not by forgetting to mask first.
  Added the stronger test `claude_call_test.dart` already had in
  `intelligent-reporting`'s pipeline: the real credential sent on the
  wire never appears anywhere in the journal's stored bytes, scanned
  directly, not just the one field a decoder happens to read back.
- Remove `Witness.prompt` and everything built for it (`PromptRecord`,
  `ReplyRecord`, `PromptId`, `ReplyEnd`/`ReplyComplete`/`ReplyCancelled`/
  `ReplyFailed`, `MaskedHeaders`, `masked`) — all of the above six entries
  describe work this package no longer does. Nick's reshape of 14 Nov:
  the conversation does not go through the airlock at all. The agent
  loop writes each turn to the journal itself, and a model call's bytes
  are recorded by whatever sends them (`claude -p`'s proxy, in
  `agent_loop`), not by `is_airlock`. `Witness` keeps only `witness`;
  `RecordedAirlock` no longer takes an `HttpClient`, since nothing here
  sends anything. Kept out of `is_airlock`'s own history is fine —
  `git log` before 14 Nov 2026 has the design if it's needed again,
  wherever it actually ends up living.
- `is_airlock` no longer holds a journal of its own at all (Nick's
  ruling, 15 Nov): `is_journal` 0.5.0's one writer service is the
  record's one writer, for every sender, and `is_airlock` is one of its
  senders. `Witness`/`RecordedAirlock` take a `RecordClient` (new),
  which sends `<kind>\n-\n<body>` over a Unix socket (the writer's own
  wire protocol) and returns an `EntryHash`, or throws `RecordRefused`
  (nothing added, safe to retry once fixed) or `RecordFailed` (the
  entry's in, its object may not be — don't retry). `follows` is always
  `-`: every entry this package sends starts its own chain; only the
  agent loop appends to a journey path's own.
- `bin/airlock_service.dart` is a pure sender now: no `Journal.open`,
  no compiled-build code hash — that's the writer service's build
  concern entirely. Takes `AIRLOCK_RECORD_SOCKET` (the writer's socket)
  alongside the existing `AIRLOCK_SOCKET_PATH`/`AIRLOCK_SOCKET_MODE`.
- Tests spin up a real `dart run is_journal:service` subprocess
  (`test/journal_service_harness.dart`) rather than reimplementing or
  mocking the writer's protocol — matching this org's preference for
  testing against the real thing throughout. Verified the whole chain
  by hand too: a real writer service, a real `bin/airlock_service.dart`,
  a real relay-shaped request, the entry landing in the journal with
  the right wire header and body, both processes exiting clean on
  `SIGTERM`.
