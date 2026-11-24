# is_airlock

An [`Airlock<R, P>`](https://github.com/intersyntactic/airlock_api) that
decides and writes to the logbook under `is_airlock_api`, sending every
entry to `is_logbook`'s one writer over a [`LogbookClient`](lib/src/logbook_client.dart).

```dart
import 'package:is_airlock/is_airlock.dart';

final airlock = Airlock<MyRules, MyPlace>(
  LogbookClient('/run/intersyntactic-logbook/writer.sock'),
  decide: (trajectory, reach, rules) => rules.allows(reach)
      ? const Allow(by: DecidedBy.rules)
      : const Deny('not under these rules', by: DecidedBy.rules),
  entryOn: entryIndex.entryOn,
  rawEntry: entryIndex.raw,
  registryByScheme: {
    ExternalSystemScheme.parse('teams')!: (
      module: const TeamsRequestsAnsweringEvents(),
      signIn: teamsSignIn,
    ),
  },
);
```

## Policy is the app's, not this package's

A trajectory's `decide` needs to know what `R`, its rules, actually
allow — and `R` is whatever the app defines. Rather than guess at a shape
for it, `Airlock` takes `decide` as a function. `P`, the host's
place-in-a-turn type that every entry carries, is likewise never read
here: it is logged however it prints, and nothing more. `entryOn` and
`rawEntry` are given as functions for the same reason: following the
logbook for what it holds is this package's to build
([`EntryIndex`](lib/src/entry_index.dart)), but is not `Airlock`'s own
concern.

`registryByScheme` is which module builds the requests answering an
event, and which sign-in they go as, keyed by the scheme of the event's
address in its external system (`teams` of `teams:19:abc@thread.v2`):
one entry per relay whose events this airlock can answer.

## What the airlock does not do

Nor does this package hold the logbook itself: `is_logbook`'s one writer
does, for every sender, and this is one of its senders. Sending a prompt
to a model is not the airlock's job either: the agent loop writes each
turn to the logbook itself, and a model call's bytes are written by
whatever sends them, not by this package.

It no longer witnesses arrivals (Nick's ruling, 16 Nov): an incoming
event is written to the logbook by whoever puts it there — `teams_module`,
once events went on the bus — not by the airlock. A tool's effect is the
airlock's whole concern now. (If you're looking for the `Witness`/
`witness()`/`ArrivalSource` design that used to live here, see this
repo's git history before 19 Nov 2026.)

## Sending to the logbook

Every entry this package sends goes through
[`LogbookClient.send`](lib/src/logbook_client.dart), one entry at a
time, over `is_logbook_client`'s own `LogbookWriter` — the one reviewed
client, not a hand-rolled copy of its wire protocol. Most entries start
their own chain (`previous` null): a decision is its own, standalone
fact. A result extends the decision it follows, which `send`'s
`previous` is for; only the agent loop appends to a trajectory's own
chain.

`send` returns the written entry's `ObjectId`, or throws:

- `LogbookRefused` — the writer refused outright (a kind this process
  isn't listed for, chain bookkeeping failing, a malformed request).
  Nothing was added; safe to retry once whatever `why` names is fixed.
- `LogbookFailed` — the entry went in, but the writer isn't sure its
  object did, or there was no telling what happened at all. Sending the
  same fact again would risk writing it twice.

Never an id on a failure: a caller that cannot tell the two apart could
go on as though something had been written when nothing was, or send it
again when it already had.

## Running the airlock as its own service

`bin/airlock_service.dart` runs the airlock as a logbook subscriber:
building one [`Trajectory`](lib/src/airlock_subscriber.dart) per path
from its `event-admitted-to-mission` and `users-assigned-to-trajectory`
entries, and reacting to each `action-proposed-by-agent-loop` entry on a
trajectory's own chain by deciding, writing to the logbook, and running
its driver.

"The airlock has no door of its own": there is no listener here for a
loop to dial. A loop only ever proposes through the logbook.

```
AIRLOCK_LOGBOOK_SOCKET=/run/intersyntactic-logbook/writer.sock \
AIRLOCK_LOGBOOK_READ_SOCKET=/run/intersyntactic-logbook/reader.sock \
AIRLOCK_WEB_DRIVER_SOCKET=/run/web-driver/web-driver.sock \
AIRLOCK_MODEL_DRIVER_SOCKETS=/etc/airlock/model-driver-sockets.json \
AIRLOCK_TEAMS_SIGN_IN=cam \
AIRLOCK_WEB_DRIVER_USER=web-driver \
  dart run bin/airlock_service.dart
```

`AIRLOCK_RECORD_SOCKET`/`AIRLOCK_RECORD_READ_SOCKET` are still accepted
in place of the two logbook socket variables above, until infra's
migration window has run — see `bin/airlock_service.dart`'s own doc
comment for the full environment, including
`AIRLOCK_PROPOSALS_ENABLED`, `AIRLOCK_WEB_DRIVER_RELEASE`, and the rest.

This binary holds no logbook of its own, so it needs no code hash and
nothing from a compiled-build story of its own — that concern belongs
entirely to the writer service's own build. `SIGTERM`/`SIGINT` stop it
accepting new proposals once the current one finishes.

## Pin

`is_airlock_api`, `is_effects`, `is_flight_rules`, `is_logbook` and
`is_logbook_client` are all hosted on pub.dev. `is_teams_module` is
git-pinned — see `pubspec.yaml`. `publish_to: none` until Nick says go;
nothing here has asked for that yet.
