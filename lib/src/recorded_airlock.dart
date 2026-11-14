import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_journal/is_journal.dart';

import 'arrival_source.dart';

/// Witnesses arrivals into a [Journal], needing no journey path's rules to
/// do it.
///
/// What a run may do is a journey path's own business — [RecordedAirlock]
/// adds that on top of this, for whoever has rules to bring. A caller with
/// no run and no rules — just arrivals to witness — builds a [Witness]
/// directly rather than inventing a policy it doesn't have.
///
/// Sending a prompt to a model is not here, and not the airlock's job at
/// all: Nick's reshape (14 Nov) has the agent loop write each turn to the
/// journal itself, and a model call's bytes recorded by whatever sends
/// them (`claude -p`'s proxy, in `agent_loop`), not by this package.
class Witness {
  Witness(this._journal);

  final Journal _journal;

  /// Witnesses [bytes] arriving from [source], before anything reads them:
  /// the airlock's own record of an arrival. `is_airlock_api` defines no
  /// `Witnessed` entry at all, and never will: no tool is involved, so the
  /// contract has nothing to guard.
  ///
  /// [bytes] is deliberately the only thing this takes about what arrived:
  /// not a type the caller has already read fields out of. Whatever a
  /// caller hands in here is what "exactly as it came" means, so a caller
  /// that has already parsed its arrival should witness the bytes it
  /// parsed from, not the fields it kept.
  ObjectId witness(
    Uint8List bytes, {
    required ArrivalSource source,
    DateTime? at,
  }) => _journal.add(
    utf8.encode(
      jsonEncode({
        'witnessed': {
          'at': (at ?? DateTime.now().toUtc()).toIso8601String(),
          'source': source.value,
          'bytes': base64Encode(bytes),
        },
      }),
    ),
  );
}

/// An [Airlock] whose record is a [Journal]: an [Entry] is one journal entry,
/// never written before its [Decided] or read before its [Returned], exactly
/// as [Airlock.record]'s contract asks.
///
/// What a run may do under `R` is the app's rules, not this package's: a
/// journey path's `R` is whatever its host defines, so [decide] and [narrows]
/// are given as functions rather than a shape this package would have to
/// guess at. What this package owns is durability — the journal, one writer,
/// chained and checked — not policy. `P`, the host's place-in-a-turn type,
/// is never read here either: it is logged by whatever it prints as, same
/// as everything else an entry carries.
final class RecordedAirlock<R, P> extends Witness implements Airlock<R, P> {
  RecordedAirlock(
    super._journal, {
    required this._decide,
    required this._narrows,
  });

  final Decision Function(Run<Object?> run, R rules) _decide;
  final bool Function(R fewer, R rules) _narrows;

  @override
  Future<Decision> decide(Run<Object?> run, R rules) async =>
      _decide(run, rules);

  @override
  bool narrows(R fewer, R rules) => _narrows(fewer, rules);

  @override
  Future<void> record(Entry<R, P> entry) async {
    _journal.add(utf8.encode(_describe(entry)));
  }
}

/// One journal line for [entry]. Human-readable, per `is_journal`'s own
/// design ("nothing checks it as it runs, so a person reads it instead"),
/// and, like the Teams relay's own log line, the reason a run was decided or
/// what became of it, never a copy of what it carried: no file text, no
/// program output.
String _describe<R, P>(Entry<R, P> entry) => switch (entry) {
  Decided(:final journeyPathId, :final place, :final run, :final decision) =>
    'decided $journeyPathId@$place ${_reach(run.reach)} -> ${_decision(decision)}',
  Returned(:final journeyPathId, :final place, :final run, :final outcome) =>
    'returned $journeyPathId@$place ${_reach(run.reach)} -> ${_outcome(outcome)}',
  Narrowed(
    :final journeyPathId,
    :final place,
    :final child,
    :final rules,
    :final granted,
  ) =>
    'narrowed $journeyPathId@$place -> $child rules=$rules granted=$granted',
};

String _reach(Reach reach) => switch (reach) {
  Reads(:final path) => 'reads $path',
  Writes(:final file) => 'writes ${file.path}',
  Starts(:final program, :final args) =>
    'starts $program ${args.args.join(' ')}',
  Sends(:final origin, :final signIn) =>
    'sends $origin as ${signIn ?? 'no sign-in'}',
};

String _decision(Decision decision) => switch (decision) {
  Allow(:final by) => 'allow (by ${by.name})',
  Deny(:final why, :final by) => 'deny (by ${by.name}): $why',
};

String _outcome(Outcome<Object?> outcome) => switch (outcome) {
  Ran() => 'ran',
  Refused(:final why) => 'refused: $why',
};
