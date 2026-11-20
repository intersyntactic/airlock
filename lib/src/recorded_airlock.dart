import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_docking_station/is_docking_station.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_logbook_client/is_logbook_client.dart' show Kind, ObjectId;

import 'record_client.dart';

/// A [DecidesAndRecordsActions] that sends what it decides and records to
/// `is_logbook`'s one writer, over a [RecordClient].
///
/// What a run may do under `R` is the app's rules, not this package's: a
/// trajectory's `R` is whatever its host defines, so [decide] is given
/// as a function rather than a shape this package would have to guess at.
/// `P`, the host's place-in-a-turn type, is never read here either: it is
/// logged by whatever it prints as, same as everything else an entry
/// carries.
///
/// [recordedOn] and [rawEntry] are given as functions too, for the same
/// reason: following the record for what it holds is genuinely this
/// package's to build (see lib/src/record_index.dart), but is not this
/// type's own concern.
final class RecordedAirlock<R, P> implements DecidesAndRecordsActions<R, P> {
  RecordedAirlock(
    this._record, {
    required this._decide,
    required this._recordedOn,
    required this._rawEntry,
    required this._registryByScheme,
  });

  final RecordClient _record;
  final Decision Function(TrajectoryId trajectory, Reach reach, R rules) _decide;
  final Future<Outcome<({String kind, String body})>> Function(
    TrajectoryId trajectory,
    EntryId entry,
  )
  _recordedOn;

  /// [id]'s own kind, previous and body, with no trajectory check: used
  /// only after [_turnStartingAdmission] has itself checked ownership of
  /// the admission entry, and for the relayed event it names, which is
  /// never on any trajectory's own chain.
  final ({String kind, ObjectId? previous, String body})? Function(EntryId id)
  _rawEntry;

  /// Which module builds the requests answering an event, and which
  /// sign-in they go as, by the scheme of its address in its external
  /// system (`teams` of `teams:19:abc@thread.v2`): one entry per relay
  /// whose events this airlock can answer. Airlock's own call
  /// (is_airlock_api's own doc on [replyRequests]: "the airlock picks the
  /// module and the sign-in the requests go as").
  final Map<String, ({BuildsRequestsAnsweringEvents module, SignIn signIn})>
  _registryByScheme;

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

  /// Writes [decision] under [AirlockDecisionOnAction.kind], as
  /// [_encodeDecision]'s human line: `is_logbook`'s own design is that
  /// nothing checks a decision as it runs, so a person reads it instead.
  /// Nothing reads a decision back structurally — an [AnswersEvent]'s own
  /// driver call is given the exact [Reach] it decided in memory, never
  /// re-read from the record.
  @override
  Future<void> recordDecision(AirlockDecisionOnAction<P> decision) async {
    _decisionHash[decision] = await _record.send(
      AirlockDecisionOnAction.kind,
      utf8.encode(_encodeDecision(decision)),
    );
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

  @override
  Future<Outcome<List<Request>>> replyRequests(
    TrajectoryId trajectory,
    EntryId respondsTo,
    ModelReply reply,
  ) => _requestsAnswering(
    trajectory,
    respondsTo,
    (module, relayedEvent, signIn) => module.replyRequests(
      relayedEvent: relayedEvent,
      reply: reply,
      signIn: signIn,
    ),
  );

  @override
  Future<Outcome<List<Request>>> trajectoryOpenedRequests(
    TrajectoryId trajectory,
  ) =>
      // The admission that started a trajectory is named by no other entry:
      // its own hash IS the trajectory id (is_airlock_api's own doc on
      // this method), so it is its own respondsTo.
      _requestsAnswering(
        trajectory,
        EntryId.parse(trajectory.hex)!,
        (module, relayedEvent, signIn) => module.trajectoryOpenedRequests(
          relayedEvent: relayedEvent,
          signIn: signIn,
        ),
      );

  /// The requests answering the event [respondsTo] admits for [trajectory],
  /// [build] run against whichever module answers its address's scheme and
  /// whichever sign-in posts for that scheme; or [Refused] with why there
  /// are none. Shared by [replyRequests] and [trajectoryOpenedRequests],
  /// which differ only in which module method [build] calls and which
  /// entry respondsTo [trajectory]'s own opening admission.
  Future<Outcome<List<Request>>> _requestsAnswering(
    TrajectoryId trajectory,
    EntryId respondsTo,
    List<Request>? Function(
      BuildsRequestsAnsweringEvents module,
      Uint8List relayedEvent,
      SignIn signIn,
    )
    build,
  ) async {
    final EventAdmittedToMission decided;
    switch (_turnStartingAdmission(trajectory, respondsTo)) {
      case Refused(:final why):
        return Refused(why);
      case Ran(output: final admission):
        decided = admission;
    }
    final scheme = _schemeOf(decided.addressInExternalSystem);
    final registered = _registryByScheme[scheme];
    if (registered == null) {
      return Refused('$respondsTo: no module answers $scheme:');
    }
    final eventEntry = _rawEntry(EntryId.parse(decided.event.hex)!);
    if (eventEntry == null) {
      return Refused('${decided.event.hex}: the relayed event is not recorded');
    }
    final relayed = RelayedEvent.read(decided.event, utf8.encode(eventEntry.body));
    if (relayed == null) {
      return Refused('${decided.event.hex} does not read back as a relayed event');
    }
    final requests = build(registered.module, relayed.bytes, registered.signIn);
    if (requests == null) {
      return Refused('$respondsTo: $scheme\'s module built no requests');
    }
    return Ran(requests);
  }

  /// [respondsTo], read back and checked to admit an event that starts a
  /// turn on [trajectory]; [Refused] with why not when it doesn't admit
  /// anything, admits under another trajectory, or starts no turn.
  ///
  /// [EventAdmittedToMission.placement] names [trajectory] directly for a
  /// later turn ([OnTrajectory]), but the admission that starts a
  /// trajectory ([StartsTrajectory]) names none: its own entry's hash IS
  /// the trajectory id ([TrajectoryId.of], is_docking_station's own
  /// `path_start.dart`), rebuilt here from what [RecordIndex.raw] already
  /// indexed rather than refetched — is_logbook 0.2.1's own wire,
  /// `<kind>\n<previous-hex-or-dash>\n<body>` (is_logbook's
  /// `lib/service.dart`'s `_append`).
  Outcome<EventAdmittedToMission> _turnStartingAdmission(
    TrajectoryId trajectory,
    EntryId respondsTo,
  ) {
    final raw = _rawEntry(respondsTo);
    if (raw == null) return Refused('$respondsTo is not recorded');
    if (Kind.parse(raw.kind) != DecisionEntryKind.eventAdmittedToMission) {
      return Refused('$respondsTo is a ${raw.kind}, not an admission');
    }
    final decision = decodeDecision(
      DecisionEntryKind.eventAdmittedToMission,
      utf8.encode(raw.body),
    );
    if (decision is! EventAdmittedToMission) {
      return Refused('$respondsTo does not read back as an admission');
    }
    if (decision.startsTurn != true) {
      return Refused('$respondsTo starts no turn');
    }
    final onThisTrajectory = switch (decision.placement) {
      OnTrajectory(trajectory: final onTrajectory) => onTrajectory == trajectory,
      StartsTrajectory() =>
        TrajectoryId.of(_entryBytes(raw.kind, raw.previous, raw.body)) ==
            trajectory,
      IntoMission() => false,
    };
    if (!onThisTrajectory) {
      return Refused('$respondsTo does not admit an event on $trajectory');
    }
    return Ran(decision);
  }

  /// [address]'s own system, the text before its first `:`: `teams` of
  /// `teams:19:abc@thread.v2` ([AddressInExternalSystem]'s own doc, "a
  /// source, a colon and the rest"), the same name [RelayedEvent.source]
  /// gives it.
  String _schemeOf(AddressInExternalSystem address) =>
      address.value.substring(0, address.value.indexOf(':'));

  /// [kind], [previous] and [body] as the bytes the record actually hashes
  /// an entry's id from: see [_turnStartingAdmission]'s own doc.
  Uint8List _entryBytes(String kind, ObjectId? previous, String body) =>
      Uint8List.fromList([
        ...utf8.encode('$kind\n${previous?.hex ?? '-'}\n'),
        ...utf8.encode(body),
      ]);
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
  AnswersEvent(:final answer, :final requests) =>
    'answers ${_answer(answer)} with ${requests.map(_request).join(', ')}',
  FetchesFromWeb(:final fetch) =>
    'fetches ${fetch.origin}${fetch.path} as ${fetch.signIn ?? 'no sign-in'}',
  CallsTheModel(:final signIn, :final model) => 'asks $model as $signIn',
};

String _answer(Answer answer) => switch (answer) {
  ReplyToEvent(:final respondsTo, :final reply) =>
    'reply to $respondsTo (model reply $reply)',
  TrajectoryOpened() => 'trajectory opened',
};

String _request(Request request) =>
    '${request.origin}${request.path} as ${request.signIn ?? 'no sign-in'}';

String _decision(Decision decision) => switch (decision) {
  Allow(:final by) => 'allow (by ${by.name})',
  Deny(:final why, :final by) => 'deny (by ${by.name}): $why',
};

String _outcome(Outcome<Object?> outcome) => switch (outcome) {
  Ran(output: final List<WebResponse> responses) =>
    'ran ${responses.map(_response).join(', ')}',
  Ran(output: WebResponse(created: final created?)) =>
    'ran created=$created',
  Ran(output: WebResponse(refusedBecause: final refusedBecause?)) =>
    'ran refusedBecause=$refusedBecause',
  Ran() => 'ran',
  Refused(:final why) => 'refused: $why',
};

String _response(WebResponse response) => switch (response) {
  WebResponse(created: final created?) => 'created=$created',
  WebResponse(refusedBecause: final refusedBecause?) => 'refusedBecause=$refusedBecause',
  _ => '${response.status}',
};
