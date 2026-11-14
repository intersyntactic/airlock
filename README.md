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

`witness` and `prompt` don't need a journey path's `R` or `P` at all —
only a journal and, for `prompt`, an HTTP client. They live on `Witness`,
which `RecordedAirlock` extends; a caller with no runs and no rules (a
pipeline sending its own prompts, say) builds a bare `Witness` directly,
rather than inventing a `decide`/`narrows` it doesn't have just to reach
`prompt` — that's the same "pose as a journey path" shape Nick ruled out
for sending itself.

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
involved in an arrival, so its contract has nothing to guard. Witnessing —
of arrivals here, and of prompts in `RecordedAirlock.prompt` below — is
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

## Sending a prompt

Going out is as recordable as coming in — and, per Nick's ruling, the
airlock is the only thing that sends: no caller holds its own connection
or its own recorder. `Witness.prompt` sends the prompt, records it
(headers masked) before anything goes, gathers the reply as it arrives,
records that too, and hands back the reply's own id alongside exactly
what it recorded:

```dart
final (replyId, reply) = await witness.prompt(
  JourneyPathId.parse('journey-name')!,
  ArrivalSource.parse('claude')!,
  to,
  bodyBytes,
  headers, // the real headers, including the credential; prompt masks
           // them for the record, but sends these exactly as given
);
// reply.status, reply.headers, reply.body, reply.end — what the journal
// holds, not a second copy of the same bytes read some other way.
```

A prompt is in the journal before it is sent — if it can't be, nothing is
sent, rather than ever letting an unrecorded prompt out. A failed send
(refused, timed out, the connection dropped) is still recorded, as a
reply with `ReplyFailed` and no status, not left unrecorded because
nothing came back. The reply's entry names the id of the prompt's entry
(`PromptId`), so the journal can always say which answers which.

`prompt` sends [headers] exactly as given, nothing more: it never adds its
own `Accept-Encoding`, and the client it makes for itself has
`autoUncompress` off, so a server's compressed reply arrives, is recorded,
and is returned as the same compressed bytes its own headers say they
are. Compression happens only when the caller's own headers ask for it —
otherwise the bytes on the wire, in the record, and handed back are
identical, which is the whole point of recording "exactly as it came."
Passing a custom client does not relax this: the header is stripped per
request regardless of which client sends it.

This followed a design Nick ruled out: an earlier version gave a caller a
`PromptTap`/`ReplyTap` it drove itself, doing its own HTTP alongside — a
sender-side recorder with the airlock as a passive backend behind it.
That let a sender hold a client of its own, which is exactly what
witnessing arrivals never allows; `prompt` closes the same gap for what
goes out. The record format — `model prompt`/`model reply`, the link, the
per-provider `source`, `JourneyPathId` `pass` — is unchanged from
`intelligent-reporting`'s original `CallTap`
(pipeline/lib/src/record_prompts.dart in
https://github.com/enspyrco/intelligent-reporting/pull/132); only who
holds the connection moved.

`masked` is exported too: the same masking `prompt` applies to a
recorded prompt's headers, for anything that still needs it directly.

What this package deliberately does *not* send: `claude -p`'s own prompts
go through a local proxy standing between it and the model, since it is a
subprocess, not an HTTP call this process makes on its own behalf. That
proxy stays in `intelligent-reporting`'s pipeline, forwarding each request
through this same `prompt` call rather than its own `HttpClient`.

## Pin

Depends on `is_airlock_api` 0.2.0 and `is_effects`, both pinned by git ref
in `pubspec.yaml` ahead of their next pub.dev releases; see the comments
there for why. `publish_to: none` until `is_airlock_api` has a published
version this package can depend on without a git pin — until then, pin this
package by its own git ref.
