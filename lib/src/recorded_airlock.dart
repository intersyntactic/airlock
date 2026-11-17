import 'dart:convert';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';

import 'record_client.dart';

/// A [DecidesAndRecordsActions] that sends what it decides and records to
/// `is_journal`'s one writer, over a [RecordClient].
///
/// What a run may do under `R` is the app's rules, not this package's: a
/// trajectory's `R` is whatever its host defines, so [decide] is given
/// as a function rather than a shape this package would have to guess at.
/// `P`, the host's place-in-a-turn type, is never read here either: it is
/// logged by whatever it prints as, same as everything else an entry
/// carries.
///
/// [renderer] and [rendered] are given as functions too, for the same
/// reason: resolving a renderer's name, and following the journal for
/// what it recorded, are both genuinely this package's to build, but not
/// yet — see lib/src/rendered.dart for [rendered]'s real logic, not yet
/// wired in here.
final class RecordedAirlock<R, P> implements DecidesAndRecordsActions<R, P> {
  RecordedAirlock(
    this._record, {
    required this._decide,
    required this._renderer,
    required this._rendered,
  });

  final RecordClient _record;
  final Decision Function(Reach reach, R rules) _decide;
  final Future<Renderer?> Function(RendererName name) _renderer;
  final Future<Outcome<String>> Function(Decided<P> decided) _rendered;

  @override
  Future<Decision> decide(Reach reach, R rules) async => _decide(reach, rules);

  @override
  Future<Renderer?> renderer(RendererName name) => _renderer(name);

  @override
  Future<Outcome<String>> rendered(Decided<P> decided) => _rendered(decided);

  /// Writes [entry] in whichever shape its reader actually needs.
  ///
  /// A [Returned] answering a proposal (Nick, 16 Nov 20:45: "what an action
  /// returns is in the record, once") is [ReturnedProposal], under its own
  /// `returned` kind: the loop's `propose()` is waiting to decode exactly
  /// that back, and a human line there would leave it waiting forever
  /// instead of failing loudly. Everything else — read/write/start actions
  /// proposed with no loop waiting, and any [Decided] — still gets
  /// [_encode]'s human line for now: `is_journal`'s own design is that
  /// nothing checks it as it runs, so a person reads it instead.
  ///
  /// A [Decided] whose reach is [MakesWebRequest] needs its own
  /// [DecidedWebRequest] wire shape too, for the renderer that subscribes to
  /// it — not done here yet (task 27: which chain its `Returned` and the
  /// renderer's `Rendered` entry go on isn't settled; airlock-api-04 flagged
  /// real uncertainty there on 17 Nov).
  @override
  Future<void> record(Entry<P> entry) async {
    if (entry is Returned<P>) {
      final proposal = ReturnedProposal.of(entry);
      if (proposal != null) {
        await _record.send(
          ReturnedProposal.kind,
          utf8.encode(jsonEncode(proposal.toJson())),
        );
        return;
      }
    }
    final (kind, body) = _encode(entry);
    await _record.send(kind, utf8.encode(body));
  }
}

/// The writer-service kind, and one journal line of body, for [entry].
/// Human-readable, per `is_journal`'s own design ("nothing checks it as it
/// runs, so a person reads it instead"); for an entry no reader decodes
/// (every case [record] doesn't give its own wire shape), never a copy of
/// what it carried: no file text, no program output.
(String, String) _encode<P>(Entry<P> entry) => switch (entry) {
  Decided(
    :final trajectoryId,
    :final place,
    :final reach,
    :final decision,
    :final proposed,
  ) =>
    (
      'decided',
      '$trajectoryId@$place ${_reach(reach)} -> ${_decision(decision)}'
          '${proposed == null ? '' : ' proposed=$proposed'}',
    ),
  Returned(
    :final trajectoryId,
    :final place,
    :final reach,
    :final outcome,
    :final proposed,
  ) =>
    (
      'returned',
      '$trajectoryId@$place ${_reach(reach)} -> ${_outcome(outcome)}'
          '${proposed == null ? '' : ' proposed=$proposed'}',
    ),
};

String _reach(Reach reach) => switch (reach) {
  Reads(:final path) => 'reads $path',
  Writes(:final file) => 'writes ${file.path}',
  Starts(:final program, :final args) =>
    'starts $program ${args.args.join(' ')}',
  MakesWebRequest(:final request, :final renderer) =>
    'sends ${request.origin}${request.path} as ${request.signIn ?? 'no sign-in'} '
    'renderer=${renderer?.id.toString() ?? 'none'} '
    'draws ${request.entries.join(',')}',
};

String _decision(Decision decision) => switch (decision) {
  Allow(:final by) => 'allow (by ${by.name})',
  Deny(:final why, :final by) => 'deny (by ${by.name}): $why',
};

String _outcome(Outcome<Object?> outcome) => switch (outcome) {
  Ran(output: WebRequestOutcome(created: final created?)) =>
    'ran created=$created',
  Ran(output: WebRequestOutcome(refusedBecause: final refusedBecause?)) =>
    'ran refusedBecause=$refusedBecause',
  Ran() => 'ran',
  Refused(:final why) => 'refused: $why',
};
