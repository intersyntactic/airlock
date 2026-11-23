/// Running the airlock as a logbook subscriber: building one [Trajectory]
/// per path from its `event-admitted-to-mission` and
/// `users-assigned-to-trajectory` entries, and reacting to each
/// `action-proposed-by-agent-loop` entry on a trajectory's own chain by
/// deciding, writing to the logbook and running its driver.
///
/// "The airlock has no door of its own" (lib/src/proposal.dart, 0.7.1): a
/// loop never reaches this service directly. It only ever follows the
/// logbook.
///
/// A decision starts a chain no trajectory owns (the logbook refuses any
/// other write there as `not-owner`, since only a trajectory's own loop
/// user may extend its chain — airlock-api-04 and teams-module-e2, 17 Nov),
/// so the logbook's tip check gives this package no "one decision per
/// proposal" for free. [runAirlockService] rebuilds which proposals already
/// have an answer from the logbook itself before deciding anything new, by
/// reading every `outcome-of-proposed-action` entry's `proposed` in
/// the backlog first.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_docking_station_api/path_start.dart'
    show
        EntryStartsTrajectory,
        EntryStartsNoTrajectory,
        UnreadableTrajectoryEntry,
        readTrajectoryStart;
import 'package:is_effects/is_effects.dart';
import 'package:is_flight_rules/is_flight_rules.dart';
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, Kind, ObjectId, Subscribed;

import 'entry_index.dart';

final _admittedKind = Kind.parse('event-admitted-to-mission')!;
final _assignedKind = Kind.parse('users-assigned-to-trajectory')!;
final _proposedKind = Kind.parse(ActionProposedByAgentLoop.kind)!;
final _resultKind = Kind.parse(outcomeOfProposedActionKind)!;

/// Under is_logbook 0.2.0, [Entry.id] (chain-walking's own space, via
/// [Entry.previous]) is the [ObjectId] of the entry's bytes — the same
/// sha256 [EntryId.of] computes over an entry's object text — so chain
/// identity and content identity are now one id space (see
/// lib/src/entry_index.dart). A proposal's wire identity
/// ([Trajectory.consider]'s `proposed`, and the `proposed` field
/// [readOutcomeOfProposedAction] reads back) is still computed as
/// [EntryId.of] the entry's `recorded` bytes directly, since that is
/// is_airlock_api's own type, not is_logbook's — equal in value, never in
/// type.

/// `users-assigned-to-trajectory`'s body: logbook-07 confirmed the shape,
/// fixed by the logbook and refused in any other (loop_launcher's task 16
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

  /// This entry's id, as [Trajectory.consider]'s `proposed` and
  /// [readOutcomeOfProposedAction]'s `proposed` name it — `is_shapes`'s
  /// [EntryId], not is_logbook's own [ObjectId]: the same sha256, a
  /// different type.
  final EntryId id;
  final Uint8List body;
  final TrajectoryId trajectory;
}

/// Runs the airlock until [subscribe]'s stream ends, which it never
/// should: the caller treats a return as the logbook going away.
///
/// A trajectory is built once it has both its rules (from
/// `event-admitted-to-mission`) and its suit (from
/// `users-assigned-to-trajectory`); the two can arrive in either order.
/// [drivers] is the same set for every trajectory — tonight, the web
/// driver and the model driver (`AsksTheModel`); no file or program driver
/// yet (scope trimmed for the demo).
///
/// Nothing is decided until the backlog has fully arrived ([CaughtUp]):
/// every `proposed` entry found before then is held in [_Buffered] rather
/// than acted on immediately, since a later `returned` entry in that same
/// backlog may show it was already answered in an earlier run of this
/// service. Once caught up, every still-unanswered buffered proposal is
/// considered, in the logbook's order, and every later one is considered as
/// it arrives.
///
/// [proposalsEnabled] is the hard gate task 20 asked for: until the logbook
/// enforces that a trajectory's chain takes entries only from its own loop
/// user, any loop user could write a `proposed` entry onto any trajectory's
/// chain, and the airlock would act on it as that trajectory's own. While
/// it is false, every `proposed` entry is ignored outright — not buffered,
/// not considered, not counted as answered — and only `rules`/`suit`
/// bookkeeping from `admitted`/`assigned` still runs. Flip it only once
/// chain ownership is confirmed live (infra-5e's `AIRLOCK_PROPOSALS_ENABLED`).
Future<void> runAirlockService({
  required Stream<Subscribed> Function() subscribe,
  required DecidesActionsAndWritesToTheLogbook<WhatMayLeaveThisMachine, PlaceInTrajectory>
  airlock,
  required Iterable<CarriesOutActions> drivers,
  required bool proposalsEnabled,
  required EntryIndex entryIndex,
  required Future<void> Function(EntryId proposed, String why) writeRejection,
  required Future<void> Function(String line) writeLogbookEntry,
  required void Function(String line) say,
}) async {
  final rulesOf = <TrajectoryId, WhatMayLeaveThisMachine>{};
  final suitOf = <TrajectoryId, Suit>{};
  final trajectories =
      <TrajectoryId, Trajectory<WhatMayLeaveThisMachine, PlaceInTrajectory>>{};
  final answered = <EntryId>{};
  final buffered = <_Buffered>[];
  var caughtUp = false;

  Trajectory<WhatMayLeaveThisMachine, PlaceInTrajectory>? build(TrajectoryId id) {
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
      return FlightRules.fromJson(object).whatMayLeaveThisMachine;
    } on FormatException {
      return null;
    }
  }

  Future<void> consider(_Buffered entry) async {
    final trajectory = build(entry.trajectory);
    if (trajectory == null) {
      const why = 'no rules or suit for this trajectory';
      say(
        '${entry.id.hex}: proposed on ${entry.trajectory.hex}, which has '
        'no rules or suit',
      );
      await writeRejection(entry.id, why);
      return;
    }
    switch (ActionProposedByAgentLoop.read(utf8.decode(entry.body))) {
      case final ActionProposedByAgentLoop proposal:
        await trajectory.consider(proposal, proposal.place, proposed: entry.id);
      case Rejected(:final why):
        say('${entry.id.hex}: proposal unreadable: $why');
        await writeRejection(entry.id, why);
    }
  }

  await for (final item in subscribe()) {
    // Indexed by id before any kind-specific handling, so every entry —
    // not just the kinds this service has a case for — carries its
    // chain's trajectory forward and is findable by EntryId for recordedOn.
    if (item case Entry(:final id, :final previous, :final kind, :final body)) {
      entryIndex.add(
        id,
        previous: previous,
        kind: kind.toString(),
        body: utf8.decode(body),
      );
    }
    switch (item) {
      case CaughtUp():
        caughtUp = true;
        say('airlock service: live');
        if (proposalsEnabled) {
          for (final entry in buffered) {
            if (answered.contains(entry.id)) {
              say('${entry.id.hex}: already answered, skipping');
            } else {
              await consider(entry);
            }
          }
        }
        buffered.clear();

      case Entry(:final kind, :final id, recorded: final recorded)
          when kind == _admittedKind:
        switch (readTrajectoryStart<WhatMayLeaveThisMachine>(
          recorded,
          rules: parseRules,
        )) {
          case EntryStartsTrajectory<WhatMayLeaveThisMachine>(
            trajectory: final trajectoryId,
            rules: final rules,
          ):
            rulesOf[trajectoryId] = rules;
            build(trajectoryId);
          case EntryStartsNoTrajectory<WhatMayLeaveThisMachine>():
            break;
          case UnreadableTrajectoryEntry<WhatMayLeaveThisMachine>(:final why):
            // is_docking_station_api's own doc on UnreadableTrajectoryEntry says
            // a rules-enforcing reader "must stop" here; safe to skip
            // instead specifically because build() already returns null for
            // a trajectory with no rules, and consider()'s own no-rules
            // branch already fail-closed-rejects every proposal on one.
            final line = '${id.hex}: admitted entry unreadable: $why';
            say(line);
            await writeLogbookEntry(line);
        }

      case Entry(:final kind, :final id, :final body)
          when kind == _assignedKind:
        final assigned = _decodeAssigned(body);
        if (assigned == null) {
          final line = '${id.hex}: not a users-assigned-to-trajectory entry';
          say(line);
          await writeLogbookEntry(line);
          break;
        }
        suitOf[assigned.trajectory] = assigned.suit;
        entryIndex.root(id, assigned.trajectory);
        build(assigned.trajectory);

      case Entry(:final kind, :final body) when kind == _resultKind:
        final read = readOutcomeOfProposedAction(utf8.decode(body));
        // Not every result entry answers a proposal (an action proposed
        // in-process, with no loop waiting, has none); only ones that do
        // tell us a proposal is already answered.
        if (read != null) answered.add(read.proposed);

      case Entry(:final kind, :final id, recorded: final recorded, :final body)
          when kind == _proposedKind:
        final onTrajectory = entryIndex.trajectoryOf(id);
        if (onTrajectory == null) {
          // Not on any live trajectory's chain: either stale, or the
          // logbook hasn't yet been made to enforce that a trajectory's
          // chain takes entries only from its own loop user (airlock-api-04,
          // 17 Nov: confirm this on the box). Ignored rather than acted on
          // under an unchecked claim of whose it is.
          say('${id.hex}: proposed entry is on no live trajectory, skipping');
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
          if (answered.contains(entry.id)) {
            say('${entry.id.hex}: already answered, skipping');
          } else {
            await consider(entry);
          }
        } else {
          buffered.add(entry);
        }

      case Entry():
        // Every other kind: not ours to act on.
        break;
    }
  }
}
