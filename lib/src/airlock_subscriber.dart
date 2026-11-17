/// Running the airlock as a record subscriber: building one [Trajectory]
/// per path from its `event-admitted-to-mission` and
/// `users-assigned-to-trajectory` entries, and reacting to each `proposed`
/// entry on a trajectory's own chain by deciding, recording and running its
/// driver.
///
/// "The airlock has no door of its own" (lib/src/proposal.dart, 0.7.1): a
/// loop never reaches this service directly. It only ever follows the
/// record.
///
/// A [Decided] starts a chain no trajectory owns (the journal refuses any
/// other write there as `not-owner`, since only a trajectory's own loop
/// user may extend its chain — airlock-api-04 and teams-module-e2, 17 Nov),
/// so the journal's tip check gives this package no "one decision per
/// proposal" for free. [runAirlockService] rebuilds which proposals already
/// have an answer from the record itself before deciding anything new, by
/// reading every `returned` entry's [ReturnedProposal.proposed] in the
/// backlog first.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_airlock_api/is_airlock_api.dart' hide Entry;
import 'package:is_docking_station/src/path_start.dart'
    show
        EntryStartsTrajectory,
        EntryStartsNoTrajectory,
        UnreadableTrajectoryEntry,
        readTrajectoryStart;
import 'package:is_effects/is_effects.dart';
import 'package:is_flight_rules/is_flight_rules.dart';
import 'package:is_journal/service.dart' show Kind;
import 'package:is_journal_client/is_journal_client.dart'
    show CaughtUp, Entry, EntryHash, Subscribed;

import 'record_index.dart';

final _admittedKind = Kind.parse('event-admitted-to-mission')!;
final _assignedKind = Kind.parse('users-assigned-to-trajectory')!;
final _proposedKind = Kind.parse('proposed')!;
final _returnedKind = Kind.parse(ReturnedProposal.kind)!;

/// Chain-walking (which trajectory an entry is on) is tracked by
/// [EntryHash], `is_journal`'s own hash of its 96-byte metadata record
/// (previous journal head, code hash, object id) — the same space
/// [Entry.hash] and [Entry.previous] are in, and NOT the same number as
/// [EntryId], which is `is_shapes`'s hash of an entry's own object bytes
/// (what it actually says, header included). The two only coincide by
/// accident on a direct hash of the same bytes, never on a real entry: a
/// proposal's wire identity ([Trajectory.consider]'s `proposed`,
/// [ReturnedProposal.proposed]) is always [EntryId.of] the entry's
/// `recorded` bytes, computed fresh — never derived from its [EntryHash].

/// This trajectory's place in a turn, for now: the proposing loop and this
/// service are the only two sides that read it, and neither exists yet
/// (Nov 17), so there is no established shape to match. Picked to agree
/// with this repo's own tests, not with anything upstream.
typedef Place = int;

/// `users-assigned-to-trajectory`'s body: logbook-07 confirmed the shape,
/// fixed by the record and refused in any other (loop_launcher's task 16
/// is to hold this type for both sides so neither keeps a copy; written to
/// the exact shape until then).
final class _Assigned {
  const _Assigned({required this.trajectory, required this.suit});

  final TrajectoryId trajectory;
  final Suit suit;
}

_Assigned? _decodeAssigned(Uint8List body) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(body));
  } on FormatException {
    return null;
  }
  if (json
      case {
        'trajectory': final String trajectory,
        'mission': final String _,
        'loopUser': final String _,
        'suit': final String suit,
      }
      when json.length == 4) {
    return switch ((TrajectoryId.parse(trajectory), Suit.parse(suit))) {
      (final t?, final s?) => _Assigned(trajectory: t, suit: s),
      _ => null,
    };
  }
  return null;
}

/// One `proposed` entry, held from the backlog until it is known whether
/// [runAirlockService] already answered it in an earlier run.
final class _Buffered {
  const _Buffered({
    required this.id,
    required this.body,
    required this.trajectory,
  });

  /// This entry's hash, as [Trajectory.consider]'s `proposed` and
  /// [ReturnedProposal.proposed] name it — `is_shapes`'s [EntryId], not
  /// `is_journal`'s own [EntryHash]: the same sha256, a different type.
  final EntryId id;
  final Uint8List body;
  final TrajectoryId trajectory;
}

/// Runs the airlock until [subscribe]'s stream ends, which it never
/// should: the caller treats a return as the record going away.
///
/// A trajectory is built once it has both its rules (from
/// `event-admitted-to-mission`) and its suit (from
/// `users-assigned-to-trajectory`); the two can arrive in either order.
/// [drivers] is the same set for every trajectory — tonight, just the web
/// driver: no file or program driver yet (scope trimmed for the demo), and
/// no model driver (`AsksTheModel` has no `Program` case in 0.7.1 to route
/// to it).
///
/// Nothing is decided until the backlog has fully arrived ([CaughtUp]):
/// every `proposed` entry found before then is held in [_Buffered] rather
/// than acted on immediately, since a later `returned` entry in that same
/// backlog may show it was already answered in an earlier run of this
/// service. Once caught up, every still-unanswered buffered proposal is
/// considered, in the record's order, and every later one is considered as
/// it arrives.
///
/// [proposalsEnabled] is the hard gate task 20 asked for: until the record
/// enforces that a trajectory's chain takes entries only from its own loop
/// user, any loop user could write a `proposed` entry onto any trajectory's
/// chain, and the airlock would act on it as that trajectory's own. While
/// it is false, every `proposed` entry is ignored outright — not buffered,
/// not considered, not counted as answered — and only `rules`/`suit`
/// bookkeeping from `admitted`/`assigned` still runs. Flip it only once
/// chain ownership is confirmed live (infra-5e's `AIRLOCK_PROPOSALS_ENABLED`).
Future<void> runAirlockService({
  required Stream<Subscribed> Function() subscribe,
  required DecidesAndRecordsActions<WhatMayLeaveThisMachine, Place> airlock,
  required Iterable<CarriesOutActions> drivers,
  required bool proposalsEnabled,
  required RecordIndex recordIndex,
  required void Function(String line) say,
}) async {
  final rulesOf = <TrajectoryId, WhatMayLeaveThisMachine>{};
  final suitOf = <TrajectoryId, Suit>{};
  final trajectories =
      <TrajectoryId, Trajectory<WhatMayLeaveThisMachine, Place>>{};
  final answered = <EntryId>{};
  final buffered = <_Buffered>[];
  var caughtUp = false;

  Trajectory<WhatMayLeaveThisMachine, Place>? build(TrajectoryId id) {
    final existing = trajectories[id];
    if (existing != null) return existing;
    final rules = rulesOf[id];
    final suit = suitOf[id];
    if (rules == null || suit == null) return null;
    return trajectories[id] = Trajectory(
      id: id,
      drivers: drivers,
      airlock: airlock,
      rules: rules,
      suit: suit,
    );
  }

  WhatMayLeaveThisMachine? parseRules(Object? json) {
    final object = JsonObject.parse(json);
    if (object == null) return null;
    try {
      return WhatMayLeaveThisMachine.fromJson(object);
    } on FormatException {
      return null;
    }
  }

  Future<void> consider(_Buffered entry) async {
    final trajectory = build(entry.trajectory);
    if (trajectory == null) {
      throw StateError(
        '${entry.id.hex}: proposed on ${entry.trajectory.hex}, which has '
        'no rules or suit',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(entry.body));
    } on FormatException catch (e) {
      say('${entry.id.hex}: proposal is not JSON: ${e.message}');
      return;
    }
    switch (Proposal.read(json)) {
      case final Proposal proposal:
        final place = switch (proposal.place) {
          final int place => place,
          _ => null,
        };
        if (place == null) {
          say('${entry.id.hex}: proposal has no valid place');
          return;
        }
        await trajectory.consider(proposal, place, proposed: entry.id);
      case Rejected(:final why):
        say('${entry.id.hex}: proposal unreadable: $why');
    }
  }

  await for (final item in subscribe()) {
    // Indexed by content before any kind-specific handling, so every
    // entry — not just the kinds this service has a case for — carries its
    // chain's trajectory forward and is findable by EntryId for recordedOn.
    if (item case Entry(
      :final hash,
      :final previous,
      recorded: final recorded,
      :final body,
    )) {
      recordIndex.add(hash, previous: previous, recorded: recorded, body: body);
    }
    switch (item) {
      case CaughtUp():
        caughtUp = true;
        say('airlock service: live');
        if (proposalsEnabled) {
          for (final entry in buffered) {
            if (!answered.contains(entry.id)) await consider(entry);
          }
        }
        buffered.clear();

      case Entry(kind: null, :final hash):
        throw StateError('${hash.hex}: entry has no kind');

      case Entry(:final kind, :final hash, recorded: final recorded)
          when kind == _admittedKind:
        switch (readTrajectoryStart<WhatMayLeaveThisMachine>(
          recorded,
          rules: parseRules,
        )) {
          case EntryStartsTrajectory<WhatMayLeaveThisMachine>(
            trajectory: final id,
            rules: final rules,
          ):
            rulesOf[id] = rules;
            build(id);
          case EntryStartsNoTrajectory<WhatMayLeaveThisMachine>():
            break;
          case UnreadableTrajectoryEntry<WhatMayLeaveThisMachine>(:final why):
            throw StateError('${hash.hex}: admitted entry unreadable: $why');
        }

      case Entry(:final kind, hash: final hash, :final body)
          when kind == _assignedKind:
        final assigned = _decodeAssigned(body);
        if (assigned == null) {
          throw StateError(
            '${hash.hex}: not a users-assigned-to-trajectory entry',
          );
        }
        suitOf[assigned.trajectory] = assigned.suit;
        recordIndex.root(hash, assigned.trajectory);
        build(assigned.trajectory);

      case Entry(:final kind, :final body) when kind == _returnedKind:
        try {
          answered.add(
            ReturnedProposal.fromJson(jsonDecode(utf8.decode(body))).proposed,
          );
        } on FormatException {
          // Not every 'returned' entry need be a ReturnedProposal (an
          // action proposed in-process, with no loop waiting, has none);
          // only ones that are tell us a proposal is already answered.
        }

      case Entry(:final kind, :final hash, recorded: final recorded, :final body)
          when kind == _proposedKind:
        final onTrajectory = recordIndex.trajectoryOf(hash);
        if (onTrajectory == null) {
          // Not on any live trajectory's chain: either stale, or the
          // journal hasn't yet been made to enforce that a trajectory's
          // chain takes entries only from its own loop user (airlock-api-04,
          // 17 Nov: confirm this on the box). Ignored rather than acted on
          // under an unchecked claim of whose it is.
          break;
        }
        // task 20's hard gate: without proposalsEnabled, chain ownership is
        // unconfirmed, so a loop user writing onto another trajectory's
        // chain would be acted on as that trajectory's own. Ignored
        // outright, not even buffered, while it's off.
        if (!proposalsEnabled) break;
        final entry = _Buffered(
          id: EntryId.of(recorded),
          body: body,
          trajectory: onTrajectory,
        );
        if (caughtUp) {
          if (!answered.contains(entry.id)) await consider(entry);
        } else {
          buffered.add(entry);
        }

      case Entry():
        // Every other kind: not ours to act on.
        break;
    }
  }
}
