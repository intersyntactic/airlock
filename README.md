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

## Witnessing an arrival

"Nothing reaches the world unseen" applies on the way in, too. Before
anything reads an arrival — parses it, decides what it means, acts on it —
`RecordedAirlock.witness` records it, exactly as it came:

```dart
airlock.witness(requestBodyBytes, source: ArrivalSource.parse('teams')!);
```

`source` is an [`ArrivalSource`](lib/src/arrival_source.dart), not a bare
`String`: this package witnesses arrivals for whatever host embeds it, not
Teams alone, so it doesn't close the set of sources over an enum — but a
string that means something still gets a type.

`is_airlock_api` defines no `Witnessed` entry, and never will: no tool is
involved in an arrival, so its contract has nothing to guard. Witnessing —
of arrivals here, and of prompts in `RecordedAirlock.prompting` below — is
entirely this package's own job. `witness` records when it arrived, where
from, and the bytes exactly as they came, as one JSON object in the
journal:

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

## Recording a prompt

Going out is as recordable as coming in. `RecordedAirlock.prompting` gives
a `PromptTap` that writes the same airlock's journal:

```dart
final tap = airlock.prompting(JourneyPathId.parse('journey-name')!);
final reply = tap.sending(ArrivalSource.parse('claude')!, to, bodyBytes, headers);
// ...send the request, feed the response to reply...
reply.status(200, responseHeaders);
reply.chunk(firstChunkBytes);
reply.chunk(nextChunkBytes);
reply.ended(const ReplyComplete());
```

A prompt is in the journal before it can go — `sending` throws, and then it
must not go, rather than ever letting an unrecorded prompt out. A reply the
journal can't take throws too, for the same reason: an answer with no
record of how it arrived is not used. The reply's entry names the id of the
prompt's entry (`PromptId`), so the journal can always say which answers
which, and it carries the reply's status, headers and how it ended
(`ReplyComplete`, `ReplyCancelled`, or `ReplyFailed` with why) — enough to
read the reply's bytes back and use exactly the text that was recorded,
never a copy made again from something else.

This is a straight port of `intelligent-reporting`'s `CallTap`
(now `PromptTap`, pipeline/lib/src/record_prompts.dart in
https://github.com/enspyrco/intelligent-reporting/pull/132), moved into
`is_airlock` since recording what crosses the airlock is this package's
job, not the pipeline's. `source` is the same `ArrivalSource` `witness`
takes; `claude` and `ollama` are separate sources, since which model
answered is provenance, not incidental to it.

`masked` is here too: a prompt's headers, with the `authorization` and
`x-api-key` credential replaced by `[masked]` wherever its value appears,
so a credential never has to be read back out of a prompt's own headers to
be kept out of the record it was sent with.

What this package deliberately does *not* record: `claude -p`'s own
prompts go through a local proxy standing between it and the model, since
it is a program, not an HTTP call this process makes. That proxy stays in
`intelligent-reporting`'s pipeline — it is a process-facing concern, is_airlock
stays a library an embedding process links in, and a journal's single
writer means the proxy would still need its own open journal either way.

## Pin

Depends on `is_airlock_api` 0.2.0 and `is_effects`, both pinned by git ref
in `pubspec.yaml` ahead of their next pub.dev releases; see the comments
there for why. `publish_to: none` until `is_airlock_api` has a published
version this package can depend on without a git pin — until then, pin this
package by its own git ref.
