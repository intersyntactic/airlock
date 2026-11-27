import 'dart:convert';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';

import 'logbook_client.dart';
import 'trajectory.dart';

/// A [DecidesActionsAndWritesToTheLogbook] that sends what it decides and
/// the entries that follow to `is_logbook`'s one writer, over a
/// [LogbookClient].
///
/// What a run may do under `R` is the app's rules, not this package's: a
/// trajectory's `R` is whatever its host defines, so [decide] is given
/// as a function rather than a shape this package would have to guess at.
/// `P`, the host's place-in-a-turn type, is never read here either: it is
/// logged by whatever it prints as, same as everything else an entry
/// carries.
///
/// [entryOn] is given as a function too, for the same reason: following the
/// logbook for what it holds is genuinely this package's to build (see
/// lib/src/entry_index.dart), but is not this type's own concern.
final class Airlock<R, P> implements DecidesActionsAndWritesToTheLogbook<R, P> {
  /// [sleep] is what [writeResult] waits on between retries of a failed
  /// write, the real clock by default — passed in so a test can make it
  /// return at once instead of actually waiting out a backoff.
  Airlock(
    this._logbook, {
    required this._decide,
    required this._entryOn,
    this._sleep = _delay,
  });

  final SendsToTheLogbook _logbook;
  final Decision Function(TrajectoryId trajectory, Reach reach, R rules) _decide;
  final Future<Outcome<({String kind, String body})>> Function(
    TrajectoryId trajectory,
    EntryId entry,
  )
  _entryOn;
  final Future<void> Function(Duration duration) _sleep;

  /// The logbook entry [writeDecision] wrote for a decision, so
  /// [writeResult] can extend its chain without a second write naming it
  /// by anything other than being the same object [Trajectory._consider]
  /// passes to both calls in turn.
  final _decisionHash = <AirlockDecisionOnAction<P>, ObjectId>{};

  @override
  Future<Decision> decide(
    TrajectoryId trajectory,
    Reach reach,
    R rules,
  ) async => _decide(trajectory, reach, rules);

  @override
  Future<Outcome<({String kind, String body})>> entryOn(
    TrajectoryId trajectory,
    EntryId entry,
  ) => _entryOn(trajectory, entry);

  /// Writes [decision] under [AirlockDecisionOnAction.kind], as
  /// [_encodeDecision]'s human line: `is_logbook`'s own design is that
  /// nothing checks a decision as it runs, so a person reads it instead.
  @override
  Future<void> writeDecision(AirlockDecisionOnAction<P> decision) async {
    _decisionHash[decision] = await _logbook.send(
      AirlockDecisionOnAction.kind,
      utf8.encode(_encodeDecision(decision)),
    );
  }

  /// Writes [result] extending [decision]'s chain.
  ///
  /// A result answering a proposal is what an action returns, kept in
  /// the logbook once: [outcomeOfProposedActionToJson], under
  /// [outcomeOfProposedActionKind]: the loop's `propose()` is waiting to
  /// decode exactly that back, and a human line there would leave it
  /// waiting forever instead of failing loudly.
  ///
  /// The action already ran by the time this is called, so its effect —
  /// a web request sent, a program started — cannot be undone by failing
  /// to record it. A [LogbookFailed] write (the logbook unreachable, or
  /// no telling whether it landed) retries with backoff until it answers,
  /// rather than crashing the whole service and risking the restart that
  /// re-decides and re-runs the same action (task 39, Nick's fix 24 Nov):
  /// retrying this exact write is safe even if the first attempt actually
  /// landed, since [LogbookClient.send] already treats [AlreadyRecorded]
  /// as success. A [LogbookRefused] write is a different problem — these
  /// exact bytes were never going in — so that still propagates at once.
  @override
  Future<void> writeResult(
    AirlockDecisionOnAction<P> decision,
    Outcome<Object?> result, {
    required Object? resultAsJson,
  }) async {
    final previous = _decisionHash.remove(decision);
    if (previous == null) {
      throw StateError(
        '${decision.trajectoryId}: writeResult called before writeDecision',
      );
    }
    final body = jsonEncode(
      outcomeOfProposedActionToJson(decision.proposed, resultAsJson),
    );
    final encoded = utf8.encode(body);
    for (var attempt = 0;; attempt++) {
      try {
        await _logbook.send(
          outcomeOfProposedActionKind,
          encoded,
          previous: previous,
        );
        return;
      } on LogbookFailed {
        await _sleep(_backoff(attempt));
      }
    }
  }

  /// Answers [proposed], a logbook entry this package never decided
  /// because it did not read as a proposal at all, with [why]: the same
  /// [outcomeOfProposedActionKind] shape [writeResult] writes for a
  /// decided-and-refused action, so the loop waiting on it is answered
  /// either way, never left waiting forever because nothing to decide was
  /// ever found.
  Future<void> writeRejection(EntryId proposed, String why) async {
    await _logbook.send(
      outcomeOfProposedActionKind,
      utf8.encode(jsonEncode(proposalRejectedToJson(proposed, why))),
    );
  }

  /// Writes [line] under [skippedMalformedEntryKind], for a historical
  /// entry [runAirlockService] skipped rather than crash-looping on: same
  /// "nothing checks it as it runs, a person reads it" pattern as
  /// [AirlockDecisionOnAction]'s own kind.
  Future<void> writeLogbookEntry(String line) async {
    await _logbook.send(skippedMalformedEntryKind, utf8.encode(line));
  }
}

/// A historical entry [runAirlockService] skipped instead of crashing on,
/// so systemd's restart-and-replay does not die on the same entry forever
/// (Nick's name, 18 Nov).
const skippedMalformedEntryKind = 'skipped-malformed-entry';

/// One logbook line of body for [decision], human-readable: `is_logbook`'s
/// own design ("nothing checks it as it runs, so a person reads it
/// instead"), never a copy of what it carried.
String _encodeDecision<P>(AirlockDecisionOnAction<P> decision) =>
    '${decision.trajectoryId}@${decision.place} ${_reach(decision.reach)} '
    '-> ${_decision(decision.decision)} proposed=${decision.proposed}';

String _reach(Reach reach) => switch (reach) {
  Reads(:final path) => 'reads $path',
  Writes(:final file) => 'writes ${file.path}',
  Starts(:final program, :final args) =>
    'starts $program ${args.args.join(' ')}',
  MakesWebRequests(:final requests) =>
    'makes web requests ${requests.map(_proposedRequest).join(', ')}',
  FetchesFromWeb(:final fetch) =>
    'fetches ${fetch.origin}${fetch.path} as ${fetch.signIn ?? 'no sign-in'}',
  RepliesToOwnConversation() => 'replies to its own conversation',
  CallsTheModel(:final signIn, :final model) => 'asks $model as $signIn',
};

String _proposedRequest(ProposedRequest request) =>
    '${request.origin}${request.path} as ${request.signIn ?? 'no sign-in'}';

String _decision(Decision decision) => switch (decision) {
  Allow(:final by) => 'allow (by ${by?.name ?? 'no rule'})',
  Deny(:final why, :final by) => 'deny (by ${by.name}): $why',
};

Future<void> _delay(Duration duration) => Future<void>.delayed(duration);

/// How long [writeResult] waits before its (0-indexed) [attempt]th retry:
/// 200ms, doubling each time, capped at 30s so a long-down logbook is
/// still checked regularly rather than ever less often. [attempt] is
/// clamped before shifting, so a long outage can't shift it into
/// overflow.
Duration _backoff(int attempt) =>
    Duration(milliseconds: 200 << attempt.clamp(0, 7));
