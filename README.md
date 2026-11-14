# is_airlock

An [`Airlock<R, P>`](https://github.com/intersyntactic/airlock_api) that
sends every decision and outcome `Airlock.record` is given — and every
arrival `witness` is given, before anything reads it — to
[`is_journal`'s one writer service](https://github.com/intersyntactic/journal),
over a Unix socket. This package holds no journal of its own: the
writer is the record's one writer, for every sender, and `is_airlock`
is one of its senders.

```dart
import 'package:is_airlock/is_airlock.dart';

final airlock = RecordedAirlock<MyRules, MyPlace>(
  RecordClient('/run/intersyntactic-record/journal.sock'),
  decide: (run, rules) => rules.allows(run.reach)
      ? const Allow(by: DecidedBy.rules)
      : const Deny('not under these rules', by: DecidedBy.rules),
  narrows: (fewer, rules) => rules.allowsNoMoreThan(fewer),
);
```

## Policy is the app's, not this package's

`Airlock<R, P>.decide` and `.narrows` need to know what `R`, the journey
path's rules, actually allow — and `R` is whatever the app defines. Rather
than guess at a shape for it, `RecordedAirlock` takes `decide` and `narrows`
as functions. `P`, the host's place-in-a-turn type that every entry
carries, is likewise never read here — `RecordedAirlock` sends it however
it prints, and nothing more.

## Witness: the part that needs no rules

`witness` doesn't need a journey path's `R` or `P` at all — only
somewhere to send to. It lives on `Witness`, which `RecordedAirlock`
extends; a caller with no runs and no rules — just arrivals to witness,
the Teams relay, say — builds a bare `Witness` directly, rather than
inventing a `decide`/`narrows` it doesn't have just to reach `witness`.

```dart
final witness = Witness(RecordClient('/run/intersyntactic-record/journal.sock'));
```

## Sending to the writer

Every entry this package sends — a witnessed arrival, a decided run, a
returned outcome, a narrowed journey path — goes over `RecordClient` as
one request, one connection: `<kind>\n-\n<body>` out, the write side
closed, one line of answer back (`is_journal`'s own writer-service
protocol). `kind` is lowercase: `witnessed`, `decided`, `returned`,
`narrowed` — a name the writer's sender table has to list for this
process's own user, or it refuses the entry.

`follows` is always `-`: every entry this package sends starts its own
chain. Nick's ruling (15 Nov): witnessing arrivals and recording
decisions are each their own, standalone fact, never continuing a
journey path's own chain of turns — only the agent loop appends to
that one.

`RecordClient.send` returns the written entry's `EntryHash`, or throws:

- `RecordRefused` — the writer refused outright (a kind this process
  isn't listed for, chain bookkeeping failing, a malformed request).
  Nothing was added; safe to retry once whatever `why` names is fixed.
- `RecordFailed` — the entry went in, but the writer isn't sure its
  object did (`is_journal`'s own `ObjectNotKept`, one layer up). Sending
  the same fact again would record it twice.

Never a hash on a failure: a caller that cannot tell the two apart could
go on as though something had been recorded when nothing was, or retry
something that is already in.

## Witnessing an arrival

"Nothing reaches the world unseen" applies on the way in, too. Before
anything reads an arrival — parses it, decides what it means, acts on it —
`Witness.witness` sends it, exactly as it came, as a `witnessed` entry:

```dart
await witness.witness(requestBodyBytes, source: ArrivalSource.parse('teams')!);
```

`source` is an [`ArrivalSource`](lib/src/arrival_source.dart), not a bare
`String`: this package witnesses arrivals for whatever host embeds it, not
Teams alone, so it doesn't close the set of sources over an enum — but a
string that means something still gets a type.

`is_airlock_api` defines no `Witnessed` entry, and never will: no tool is
involved in an arrival, so its contract has nothing to guard. Witnessing
an arrival is entirely this package's own job. The body sent is when it
arrived, where from, and the bytes exactly as they came, as JSON:

```json
{"at": "2026-11-14T01:23:45.000Z", "source": "teams", "bytes": "<base64>"}
```

### What "exactly as it came" means for a caller that has already parsed something

`witness` takes raw bytes and nothing else — deliberately not a type a
caller has already read fields out of. A gate that verifies a request's
signature and then extracts the fields it cares about (text, entities,
`replyTo`, say) has, by the time it holds those fields, already decided what
of the arrival matters. That decision is exactly the kind of thing a witness
should outlive: next month's bug might be in which field the gate chose to
keep.

So the bytes a caller should hand `witness` are the verified request body —
the last point before anything reads the arrival for meaning, not after.
A caller holding a parsed type instead should witness the bytes it parsed
*from*, not the fields it kept. This also settles, for free, whatever the
parsed type's own shape leaves ambiguous (a chat reply's quote tag versus a
`replyToId` the parser chose not to keep, for one): the raw bytes hold
everything either reading would need, so neither has to be trusted to have
picked the right fields.

## Sending a prompt is not this package's job

An earlier version of this package sent prompts to a model too
(`Witness.prompt`, a credential-masking `MaskedHeaders` type, the whole
`CallTap`-derived record format ported from `intelligent-reporting`).
Nick's reshape of 14 Nov removed it: the conversation does not go
through the airlock at all. The agent loop writes each turn to the
journal itself, and a model call's bytes are recorded by whatever sends
them — `claude -p`'s proxy, in `agent_loop` — not by this package. The
airlock writes only what it decides (effects) and what it witnesses
arriving from outside (Teams messages and the like).

If you're looking for that code, it isn't here any more — see this
repo's git history before 14 Nov 2026 if you need the design it was
based on.

## Running the airlock as its own service

`bin/airlock_service.dart` runs `witness` as a standalone process, over a
Unix socket, for a client that cannot reach the writer service itself —
the Teams relay, at least today. One client connection, one JSON request
line (`{"source": ..., "bytes": ...}`), one JSON response line back:
`{"id": ...}` once the writer has answered `ok`, or `{"error": ...}` on
any failure — never a success on a failure. A `RecordFailed` answers with
`{"error": ..., "retry": false}`: the entry may already be in, so the
same request must not be sent again.

```
AIRLOCK_RECORD_SOCKET=/run/intersyntactic-record/journal.sock \
AIRLOCK_SOCKET_PATH=/run/airlock/airlock.sock \
  dart run bin/airlock_service.dart
```

The socket is created mode `600` by default; set `AIRLOCK_SOCKET_MODE`
(e.g. `660`) for a client running as a different user, which then grants
itself access via its own unit's `SupplementaryGroups=`, not a directory
setting — a systemd `RuntimeDirectory` is owned by its own unit's
`User`/`Group`, with no way to set that apart.

This binary holds no journal of its own, so it needs no code hash and
nothing from `is_journal`'s compiled-build story — that concern belongs
entirely to the writer service's own build now. `SIGTERM`/`SIGINT` stop
it accepting new connections, wait for every connection already being
handled to finish, then remove the socket file.

## Pin

`is_airlock_api` and `is_effects` are hosted on pub.dev. `is_journal` is
git-pinned at its `writer-service` commit (0.5.0, the writer service and
its wire protocol), not yet on pub.dev — see the comment in
`pubspec.yaml`. `publish_to: none` until Nick says go; nothing here has
asked for that yet.
