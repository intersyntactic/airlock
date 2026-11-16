import 'dart:convert';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';

import 'record_client.dart';

/// An [Airlock] that sends what it decides and records to `is_journal`'s
/// one writer, over a [RecordClient].
///
/// What a run may do under `R` is the app's rules, not this package's: a
/// journey path's `R` is whatever its host defines, so [decide] is given
/// as a function rather than a shape this package would have to guess at.
/// `P`, the host's place-in-a-turn type, is never read here either: it is
/// logged by whatever it prints as, same as everything else an entry
/// carries.
final class RecordedAirlock<R, P> implements Airlock<R, P> {
  RecordedAirlock(this._record, {required this._decide});

  final RecordClient _record;
  final Decision Function(Reach reach, R rules) _decide;

  @override
  Future<Decision> decide(Reach reach, R rules) async => _decide(reach, rules);

  @override
  Future<void> record(Entry<P> entry) async {
    final (kind, body) = _encode(entry);
    await _record.send(kind, utf8.encode(body));
  }
}

/// The writer-service kind, and one journal line of body, for [entry].
/// Human-readable, per `is_journal`'s own design ("nothing checks it as it
/// runs, so a person reads it instead"), and, like the Teams relay's own
/// log line, the reason a run was decided or what became of it, never a
/// copy of what it carried: no file text, no program output.
(String, String) _encode<P>(Entry<P> entry) => switch (entry) {
  Decided(:final journeyPathId, :final place, :final reach, :final decision) => (
    'decided',
    '$journeyPathId@$place ${_reach(reach)} -> ${_decision(decision)}',
  ),
  Returned(:final journeyPathId, :final place, :final reach, :final outcome) => (
    'returned',
    '$journeyPathId@$place ${_reach(reach)} -> ${_outcome(outcome)}',
  ),
};

String _reach(Reach reach) => switch (reach) {
  Reads(:final path) => 'reads $path',
  Writes(:final file) => 'writes ${file.path}',
  Starts(:final program, :final args) =>
    'starts $program ${args.args.join(' ')}',
  Sends(:final post, :final renderer) =>
    'sends ${post.origin}${post.path} as ${post.signIn ?? 'no sign-in'} '
    'renderer=${renderer?.id.toString() ?? 'none'} '
    'draws ${post.entries.join(',')}',
};

String _decision(Decision decision) => switch (decision) {
  Allow(:final by) => 'allow (by ${by.name})',
  Deny(:final why, :final by) => 'deny (by ${by.name}): $why',
};

String _outcome(Outcome<Object?> outcome) => switch (outcome) {
  Ran(output: Sent(created: final created?)) => 'ran created=$created',
  Ran() => 'ran',
  Refused(:final why) => 'refused: $why',
};
