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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart' show StreamGroup;
import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart'
    show ReplyEndpoint;
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
import 'trajectory.dart';

final _admittedKind = Kind.parse('event-admitted-to-mission')!;
final _assignedKind = Kind.parse('users-assigned-to-trajectory')!;
final _proposedKind = Kind.parse(ActionProposedByAgentLoop.kind)!;
final _resultKind = Kind.parse(outcomeOfProposedActionKind)!;
final _trajectoryClosedKind = Kind.trajectoryClosed;

/// Merged into [runAirlockService]'s subscription to mean "stop here":
/// its own type, never mistaken for a real [Subscribed] item.
final class _Drain {
  const _Drain();
}

/// [ProcessSignal.sigterm.watch] itself, watched lazily on [listen] rather
/// than eagerly here, so [runAirlockService]'s default for [drainOn] can
/// be this type's own compile-time constant instead of a stream only
/// built when something actually subscribes to it.
final class _WatchesProcessSigterm extends Stream<void> {
  const _WatchesProcessSigterm();

  @override
  StreamSubscription<void> listen(
    void Function(void event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => ProcessSignal.sigterm.watch().map((_) {}).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

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

/// `trajectory-closed`'s `trajectory` field, the only one [runAirlockService]
/// reads: `is_docking_station_api`'s two cases (closed because a person
/// asked, closed by an operator) otherwise differ in shape, so nothing here
/// assumes a fixed field count the way [_decodeAssigned] can.
TrajectoryId? _decodeTrajectoryClosed(Uint8List body) {
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(body));
  } on FormatException {
    return null;
  }
  return switch (json) {
    {'trajectory': final String trajectory} => TrajectoryId.parse(trajectory),
    _ => null,
  };
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
/// `users-assigned-to-trajectory`); the two can arrive in either order. A
/// proposal considered before both have arrived is held, not refused (task
/// 55, Case A): [consider] puts it under its trajectory id until either the
/// trajectory builds (decided normally, just late) or its `trajectory-closed`
/// entry arrives (refused, since nothing will ever decide it now) — see
/// `awaitingTrajectory` below. An admitted entry that fails to parse at all
/// is the one case decided immediately: its trajectory can never get real
/// rules, so anything held for it is refused as soon as that's known, not
/// left to wait on a `trajectory-closed` entry that may be a long time
/// coming, or none at all.
///
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
  required DecidesActionsAndWritesToTheLogbook<FlightRules, PlaceInTrajectory>
  airlock,
  required Iterable<CarriesOutActions> drivers,
  required bool proposalsEnabled,
  required EntryIndex entryIndex,
  required Future<void> Function(EntryId proposed, String why) writeRejection,
  required Future<void> Function(String line) writeLogbookEntry,
  required void Function(String line) say,
  void Function(TrajectoryId trajectory, ReplyEndpoint? replyEndpoint)?
  onTrajectoryStarted,
  WritesSlackReplyRequests? slackReplies,
  WritesWebAddressReplyRequests? webAddressReplies,
  Stream<void> drainOn = const _WatchesProcessSigterm(),
}) async {
  final rulesOf = <TrajectoryId, FlightRules>{};
  final suitOf = <TrajectoryId, Suit>{};
  final trajectories =
      <TrajectoryId, Trajectory<FlightRules, PlaceInTrajectory>>{};
  final answered = <EntryId>{};
  final buffered = <_Buffered>[];
  var caughtUp = false;

  // Case A (task 55): a proposal whose trajectory has no rules or suit
  // *yet* is not the same as one that never will. Held here instead of
  // answered Refused outright, it waits for whichever comes first: the
  // trajectory's own admitted/assigned entries (released below, once
  // build() succeeds), or its trajectory-closed entry (refused below,
  // since nothing will ever decide it now). No timeout: a cap short enough
  // to matter would still have lost 20 Nov's DM, which answered 7 minutes
  // late; the loop waiting on an answer already just blocks, so a late
  // answer costs lateness, not silence.
  final awaitingTrajectory = <TrajectoryId, List<_Buffered>>{};

  // A trajectory [refuseAwaiting] has already answered for, by why: known
  // dead *before* some later proposal for it is ever considered (an
  // unreadable admission, or a trajectory-closed entry, can both arrive
  // ahead of the proposal they doom), so [consider] checks this first
  // rather than only draining whoever happened to be waiting already.
  final deadTrajectory = <TrajectoryId, String>{};

  Trajectory<FlightRules, PlaceInTrajectory>? build(TrajectoryId id) {
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
      slackReplies: slackReplies,
      webAddressReplies: webAddressReplies,
    );
  }

  FlightRules? parseRules(Object? json) {
    final object = JsonObject.parse(json);
    if (object == null) return null;
    try {
      return FlightRules.fromJson(object);
    } on FormatException {
      return null;
    }
  }

  Future<void> consider(_Buffered entry) async {
    final dead = deadTrajectory[entry.trajectory];
    if (dead != null) {
      await writeRejection(entry.id, dead);
      return;
    }
    final trajectory = build(entry.trajectory);
    if (trajectory == null) {
      say(
        '${entry.id.hex}: proposed on ${entry.trajectory.hex}, which has '
        'no rules or suit yet — held until it does or the trajectory closes',
      );
      awaitingTrajectory.putIfAbsent(entry.trajectory, () => []).add(entry);
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

  /// [id] just became buildable (or, for the unreadable-admission case
  /// below, is now known never to be): reconsider every proposal
  /// [consider] held for it.
  Future<void> releaseAwaiting(TrajectoryId id) async {
    final waiting = awaitingTrajectory.remove(id);
    if (waiting == null) return;
    for (final entry in waiting) {
      if (answered.contains(entry.id)) {
        say('${entry.id.hex}: already answered, skipping');
      } else {
        await consider(entry);
      }
    }
  }

  /// [id] will never get rules or suit now: refuse everything [consider]
  /// already held for it, and mark it so a proposal considered for the
  /// first time after this point is refused immediately rather than held.
  Future<void> refuseAwaiting(TrajectoryId id, String why) async {
    deadTrajectory[id] = why;
    final waiting = awaitingTrajectory.remove(id);
    if (waiting == null) return;
    for (final entry in waiting) {
      say('${entry.id.hex}: $why, refusing');
      await writeRejection(entry.id, why);
    }
  }

  // Merged with [drainOn] rather than watched separately (task 39, Nick's
  // fix 24 Nov): this loop only ever awaits one thing at a time (every
  // branch below ends in an await before the next item is pulled), so a
  // signal here — arriving in the merged order, same as any other item —
  // is enough. [_Drain] breaks the loop once whatever was already
  // in-flight finishes; nothing after it is ever pulled or started.
  final merged = StreamGroup.merge<Object>([
    subscribe(),
    drainOn.map((_) => const _Drain()),
  ]);

  await for (final raw in merged) {
    if (raw is _Drain) {
      say('airlock service: draining (stop signal received)');
      break;
    }
    if (raw is! Subscribed) continue;
    final item = raw;
    // Indexed by id before any kind-specific handling, so every entry —
    // not just the kinds this service has a case for — is findable by
    // EntryId for recordedOn. Its trajectory is the service's own stamp
    // (is_logbook 0.5.0, is_logbook_client 0.4.0), not walked here.
    if (item case Entry(
      :final id,
      :final trajectory,
      :final kind,
      :final body,
    )) {
      entryIndex.add(
        id,
        trajectory: trajectory,
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
        switch (readTrajectoryStart<FlightRules>(recorded, rules: parseRules)) {
          case EntryStartsTrajectory<FlightRules>(
            trajectory: final trajectoryId,
            rules: final rules,
            replyEndpoint: final replyEndpoint,
          ):
            rulesOf[trajectoryId] = rules;
            onTrajectoryStarted?.call(trajectoryId, replyEndpoint);
            if (build(trajectoryId) != null) await releaseAwaiting(trajectoryId);
          case EntryStartsNoTrajectory<FlightRules>():
            break;
          case UnreadableTrajectoryEntry<FlightRules>(:final why):
            // is_docking_station_api's own doc on UnreadableTrajectoryEntry says
            // a rules-enforcing reader "must stop" here; safe to skip instead
            // specifically because this trajectory can never get real rules
            // now — TrajectoryId.of(recorded) is a pure hash, readable even
            // though the JSON it names wasn't, so whatever consider() is
            // holding for it is refused immediately rather than left waiting
            // on rules that will never arrive.
            final line = '${id.hex}: admitted entry unreadable: $why';
            say(line);
            await writeLogbookEntry(line);
            await refuseAwaiting(
              TrajectoryId.of(recorded),
              'admitted entry unreadable: $why',
            );
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
        if (build(assigned.trajectory) != null) {
          await releaseAwaiting(assigned.trajectory);
        }

      case Entry(:final kind, :final id, :final body)
          when kind == _trajectoryClosedKind:
        // Only reached for a trajectory [awaitingTrajectory] is holding
        // proposals for: one that already has rules and suit built its
        // Trajectory already and takes trajectory-closed's effect (the
        // logbook refusing further writes on its chains) with no help
        // from this case.
        final closed = _decodeTrajectoryClosed(body);
        if (closed == null) {
          final line = '${id.hex}: not a trajectory-closed entry';
          say(line);
          await writeLogbookEntry(line);
          break;
        }
        await refuseAwaiting(
          closed,
          'trajectory ${closed.hex} closed before it had rules or suit',
        );

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
