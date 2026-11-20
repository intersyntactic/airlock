import 'dart:convert';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';

import 'record_client.dart';

/// A [DecidesAndRecordsActions] that sends what it decides and records to
/// `is_logbook`'s one writer, over a [RecordClient].
///
/// What a run may do under `R` is the app's rules, not this package's: a
/// trajectory's `R` is whatever its host defines, so [decide] is given
/// as a function rather than a shape this package would have to guess at.
/// `P`, the host's place-in-a-turn type, is never read here either: it is
/// logged by whatever it prints as, same as everything else an entry
/// carries, except for a web request's decision, whose wire shape needs it
/// as JSON — [placeToJson] does that conversion, since this package does
/// not know what `P` actually is.
///
/// [recordedOn] is given as a function too, for the same reason: following
/// the record for what it holds is genuinely this package's to build (see
/// lib/src/record_index.dart), but is not this type's own concern.
final class RecordedAirlock<R, P> implements DecidesAndRecordsActions<R, P> {
  RecordedAirlock(
    this._record, {
    required this._decide,
    required this._recordedOn,
    required this._placeToJson,
  });

  final RecordClient _record;
  final Decision Function(TrajectoryId trajectory, Reach reach, R rules) _decide;
  final Future<Outcome<({String kind, String body})>> Function(
    TrajectoryId trajectory,
    EntryId entry,
  )
  _recordedOn;
  final Object? Function(P place) _placeToJson;

  /// The logbook entry [recordDecision] wrote for a decision, so
  /// [recordResult] can extend its chain without a second write naming it
  /// by anything other than being the same object [Trajectory._consider]
  /// passes to both calls in turn.
  final _decisionHash = <AirlockDecisionOnAction<P>, ObjectId>{};

  @override
  Future<Decision> decide(TrajectoryId trajectory, Reach reach, R rules) async =>
      _decide(trajectory, reach, rules);

  @override
  Future<Outcome<({String kind, String body})>> recordedOn(
    TrajectoryId trajectory,
    EntryId entry,
  ) => _recordedOn(trajectory, entry);

  /// Writes [decision] in whichever shape its reader actually needs.
  ///
  /// A [MakesWebRequest] decision gets [AirlockDecisionOnWebRequest]'s own
  /// wire shape, under its own kind, since the exact request bytes it
  /// carries are read back by this package itself (`MakeWebRequest._make`,
  /// through [recordedOn]). Every other reach gets [_encode]'s human line
  /// under [AirlockDecisionOnAction.kind]: `is_logbook`'s own design is that
  /// nothing checks it as it runs, so a person reads it instead.
  @override
  Future<void> recordDecision(AirlockDecisionOnAction<P> decision) async {
    final webRequest = AirlockDecisionOnWebRequest.of(decision, _placeToJson);
    final (kind, body) = webRequest != null
        ? (AirlockDecisionOnWebRequest.kind, jsonEncode(webRequest.toJson()))
        : (AirlockDecisionOnAction.kind, _encodeDecision(decision));
    _decisionHash[decision] = await _record.send(kind, utf8.encode(body));
  }

  /// Writes [result] extending [decision]'s chain.
  ///
  /// A result answering a proposal (Nick, 16 Nov 20:45: "what an action
  /// returns is in the record, once") is [outcomeOfProposedActionToJson],
  /// under [outcomeOfProposedActionKind]: the loop's `propose()` is
  /// waiting to decode exactly that back, and a human line there would
  /// leave it waiting forever instead of failing loudly. An action proposed
  /// in this service's own process, with no loop waiting, still records
  /// [resultAsJson] in full, so a web response's redirects and kept body
  /// never depend on whether a proposal answered it, with [_encodeResult]'s
  /// human line alongside it as an extra, never instead.
  @override
  Future<void> recordResult(
    AirlockDecisionOnAction<P> decision,
    Outcome<Object?> result, {
    required Object? resultAsJson,
  }) async {
    final previous = _decisionHash.remove(decision);
    if (previous == null) {
      throw StateError(
        '${decision.trajectoryId}: recordResult called before recordDecision',
      );
    }
    final proposed = decision.proposed;
    final (kind, body) = proposed != null
        ? (
            outcomeOfProposedActionKind,
            jsonEncode(outcomeOfProposedActionToJson(proposed, resultAsJson)),
          )
        : (
            'result',
            jsonEncode({
              'result': resultAsJson,
              'line': _encodeResult(decision, result),
            }),
          );
    await _record.send(kind, utf8.encode(body), previous: previous);
  }

  /// Answers [proposed], a logbook entry this package never decided
  /// because it did not read as a proposal at all, with [why]: the same
  /// [outcomeOfProposedActionKind] shape [recordResult] writes for a
  /// decided-and-refused action, so the loop waiting on it is answered
  /// either way, never left waiting forever because nothing to decide was
  /// ever found.
  Future<void> recordRejection(EntryId proposed, String why) async {
    await _record.send(
      outcomeOfProposedActionKind,
      utf8.encode(jsonEncode(proposalRejectedToJson(proposed, why))),
    );
  }

  /// Records [line] under [skippedMalformedEntryKind], for a historical
  /// entry [runAirlockService] skipped rather than crash-looping on: same
  /// "nothing checks it as it runs, a person reads it" pattern as
  /// [AirlockDecisionOnAction]'s own kind.
  Future<void> writeLogbookEntry(String line) async {
    await _record.send(skippedMalformedEntryKind, utf8.encode(line));
  }
}

/// A historical entry [runAirlockService] skipped instead of crashing on,
/// so systemd's restart-and-replay does not die on the same entry forever
/// (Nick's name, 18 Nov).
const skippedMalformedEntryKind = 'skipped-malformed-entry';

/// One journal line of body for [decision], human-readable: `is_logbook`'s
/// own design ("nothing checks it as it runs, so a person reads it
/// instead"), never a copy of what it carried.
String _encodeDecision<P>(AirlockDecisionOnAction<P> decision) =>
    '${decision.trajectoryId}@${decision.place} ${_reach(decision.reach)} '
    '-> ${_decision(decision.decision)}'
    '${decision.proposed == null ? '' : ' proposed=${decision.proposed}'}';

/// As [_encodeDecision], for the result following [decision].
String _encodeResult<P>(AirlockDecisionOnAction<P> decision, Outcome<Object?> result) =>
    '${decision.trajectoryId}@${decision.place} ${_reach(decision.reach)} '
    '-> ${_outcome(result)}'
    '${decision.proposed == null ? '' : ' proposed=${decision.proposed}'}';

String _reach(Reach reach) => switch (reach) {
  Reads(:final path) => 'reads $path',
  Writes(:final file) => 'writes ${file.path}',
  Starts(:final program, :final args) =>
    'starts $program ${args.args.join(' ')}',
  MakesWebRequest(:final request) =>
    'sends ${request.origin}${request.path} as ${request.signIn ?? 'no sign-in'} '
    'projection=${request.projection.wire} drawnFrom=${request.drawnFrom}',
  CallsTheModel(:final signIn, :final model) => 'asks $model as $signIn',
};

String _decision(Decision decision) => switch (decision) {
  Allow(:final by) => 'allow (by ${by.name})',
  Deny(:final why, :final by) => 'deny (by ${by.name}): $why',
};

String _outcome(Outcome<Object?> outcome) => switch (outcome) {
  Ran(output: WebResponse(created: final created?)) =>
    'ran created=$created',
  Ran(output: WebResponse(refusedBecause: final refusedBecause?)) =>
    'ran refusedBecause=$refusedBecause',
  Ran() => 'ran',
  Refused(:final why) => 'refused: $why',
};
