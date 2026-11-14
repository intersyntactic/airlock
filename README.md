# is_airlock

An [`Airlock<R>`](https://github.com/intersyntactic/airlock_api) whose
record is an add-only [`Journal`](https://github.com/intersyntactic/journal):
every decision and outcome `Airlock.record` is given becomes one journal
entry, and every arrival — before anything reads it — is witnessed into the
same journal.

```dart
import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';

final journal = Journal.open(Directory('journal'))!;
final airlock = JournalAirlock<MyRules>(
  journal,
  decide: (run, rules) => rules.allows(run.reach)
      ? const Allow(by: DecidedBy.rules)
      : const Deny('not under these rules', by: DecidedBy.rules),
  narrows: (fewer, rules) => rules.allowsNoMoreThan(fewer),
);
```

## Policy is the app's, not this package's

`Airlock<R>.decide` and `.narrows` need to know what `R`, the journey path's
rules, actually allow — and `R` is whatever the app defines. Rather than
guess at a shape for it, `JournalAirlock` takes `decide` and `narrows` as
functions. What this package owns is the record: durable, add-only, one
writer at a time, chained and checked, because that part needs no app-specific
knowledge to get right.

## Witnessing an arrival

"Nothing reaches the world unseen" applies on the way in, too. Before
anything reads an arrival — parses it, decides what it means, acts on it —
`JournalAirlock.witness` records it, exactly as it came:

```dart
airlock.witness(requestBodyBytes, source: 'teams');
```

`is_airlock_api` 0.2.0 has no `Witnessed` entry for this; one is planned for
0.3.0. Until then, `witness` writes the same three things a `Witnessed`
entry will need — when it arrived, where from, the bytes exactly as they
came — as its own JSON object in the journal, so moving to a typed entry
later is a rename, not a reshape:

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

## Pin

Depends on `is_airlock_api` 0.2.0 and `is_effects`, both pinned by git ref
in `pubspec.yaml` ahead of their next pub.dev releases; see the comments
there for why. `publish_to: none` until `is_airlock_api` has a published
version this package can depend on without a git pin — until then, pin this
package by its own git ref.
