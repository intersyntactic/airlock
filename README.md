# is_airlock

An [`Airlock<R, P>`](https://github.com/intersyntactic/airlock_api) whose
record is an add-only [`Journal`](https://github.com/intersyntactic/journal):
every decision and outcome `Airlock.record` is given becomes one journal
entry, and every arrival — before anything reads it — is witnessed into the
same journal.

```dart
import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';

final journal = Journal.open(Directory('journal'))!;
final airlock = RecordedAirlock<MyRules, MyPlace>(
  journal,
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
as functions. What this package owns is the record: durable, add-only, one
writer at a time, chained and checked, because that part needs no
app-specific knowledge to get right. `P`, the host's place-in-a-turn type
that every entry now carries, is likewise never read here — `RecordedAirlock`
logs it however it prints, and nothing more.

## Witness: the part that needs no rules

`witness` doesn't need a journey path's `R` or `P` at all — only a
journal. It lives on `Witness`, which `RecordedAirlock` extends; a
caller with no runs and no rules — just arrivals to witness, the Teams
relay, say — builds a bare `Witness` directly, rather than inventing a
`decide`/`narrows` it doesn't have just to reach `witness`.

```dart
final witness = Witness(journal);
```

## Witnessing an arrival

"Nothing reaches the world unseen" applies on the way in, too. Before
anything reads an arrival — parses it, decides what it means, acts on it —
`Witness.witness` records it, exactly as it came:

```dart
airlock.witness(requestBodyBytes, source: ArrivalSource.parse('teams')!);
```

`source` is an [`ArrivalSource`](lib/src/arrival_source.dart), not a bare
`String`: this package witnesses arrivals for whatever host embeds it, not
Teams alone, so it doesn't close the set of sources over an enum — but a
string that means something still gets a type.

`is_airlock_api` defines no `Witnessed` entry, and never will: no tool is
involved in an arrival, so its contract has nothing to guard. Witnessing
an arrival is entirely this package's own job. `witness` records when it
arrived, where from, and the bytes exactly as they came, as one JSON
object in the journal:

```json
{"witnessed": {"at": "2026-11-14T01:23:45.000Z", "source": "teams", "bytes": "<base64>"}}
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
Unix socket, for a host that can't hold a journal itself — the Teams
relay, once it stops compiling `is_journal` straight in. One client
connection, one JSON request line (`{"source": ..., "bytes": ...}`), one
JSON response line back: `{"id": ...}` once the journal's `add` has
returned, or `{"error": ...}` on any failure — never a success on a
failure, since a client unable to tell the two apart could carry on as
though something had been recorded when nothing was. An `ObjectNotKept`
failure (the entry went in, its object did not) answers with `{"error":
..., "entry": ...}`: the entry named is already recorded, so the same
request must not be retried, or it records the arrival a second time.

```
AIRLOCK_JOURNAL_DIR=/var/lib/airlock/journal \
AIRLOCK_SOCKET_PATH=/run/airlock/airlock.sock \
  dart run bin/airlock_service.dart
```

The socket is created mode `600`; a systemd `RuntimeDirectory` with a
narrower group is the intended deployment, not the mode alone. `SIGTERM`
or `SIGINT` stops it from accepting new connections, waits for every
connection already being handled to finish, then closes the journal and
removes the socket file — a connection still in flight when the signal
arrives is never asked to record into a journal that has already given
up its claim.

`is_journal` 0.3.0+ can run in a compiled build, given its code hash at
build time:

```
dart compile exe $(dart run is_journal:code_hash) bin/airlock_service.dart
```

Run from source (`dart run`), no define is needed. Either way, this
being a separate process is still the point: a relay that only talks to
it over the socket carries no `is_journal` dependency of its own, and
can be compiled whether or not this service is.

## Pin

Depends on `is_airlock_api` 0.2.0 and `is_effects`, both pinned by git ref
in `pubspec.yaml` ahead of their next pub.dev releases; see the comments
there for why. `publish_to: none` until `is_airlock_api` has a published
version this package can depend on without a git pin — until then, pin this
package by its own git ref.
