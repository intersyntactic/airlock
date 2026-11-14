import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_journal/is_journal.dart';

import 'arrival_source.dart';
import 'prompt_recording.dart';

/// An [Airlock] whose record is a [Journal]: an [Entry] is one journal entry,
/// never written before its [Decided] or read before its [Returned], exactly
/// as [Airlock.record]'s contract asks.
///
/// What a run may do under `R` is the app's rules, not this package's: a
/// journey path's `R` is whatever its host defines, so [decide] and [narrows]
/// are given as functions rather than a shape this package would have to
/// guess at. What this package owns is durability — the journal, one writer,
/// chained and checked — not policy.
final class RecordedAirlock<R> implements Airlock<R> {
  RecordedAirlock(
    this._journal, {
    required this._decide,
    required this._narrows,
  });

  final Journal _journal;
  final Decision Function(Run<Object?> run, R rules) _decide;
  final bool Function(R fewer, R rules) _narrows;

  @override
  Future<Decision> decide(Run<Object?> run, R rules) async =>
      _decide(run, rules);

  @override
  bool narrows(R fewer, R rules) => _narrows(fewer, rules);

  @override
  Future<void> record(Entry entry) async {
    _journal.add(utf8.encode(_describe(entry)));
  }

  /// Witnesses [bytes] arriving from [source], before anything reads them:
  /// the airlock's own record of an arrival, kept in the same journal as
  /// every [Entry], an entry [Airlock.record] has no way to take yet.
  ///
  /// `is_airlock_api` has no `Witnessed` entry until 0.3.0. Until it does,
  /// this writes the same three things a `Witnessed` would need — when it
  /// arrived, where from, and the bytes exactly as they came — as one JSON
  /// object, so the move to a typed entry is a rename, not a reshape.
  ///
  /// [bytes] is deliberately the only thing this takes about what arrived:
  /// not a type the caller has already read fields out of. Whatever a
  /// caller hands in here is what "exactly as it came" will mean once
  /// `Witnessed` exists, so a caller that has already parsed its arrival
  /// should witness the bytes it parsed from, not the fields it kept.
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

  /// Records prompts made under [pass] in this airlock's journal: before
  /// each goes up, no way to send it unrecorded, and the reply naming the
  /// prompt it answers, with its status, headers and how it ended. Not
  /// `witness`'s job — a reply's record needs more than bytes and a source,
  /// and a prompt going out is not an arrival.
  PromptTap prompting(JourneyPathId pass, {DateTime Function()? now}) =>
      PromptTap(_journal, pass, now: now);
}

/// One journal line for [entry]. Human-readable, per `is_journal`'s own
/// design ("nothing checks it as it runs, so a person reads it instead"),
/// and, like the Teams relay's own log line, the reason a run was decided or
/// what became of it, never a copy of what it carried: no file text, no
/// program output.
String _describe(Entry entry) => switch (entry) {
  Decided(:final journeyPathId, :final run, :final decision) =>
    'decided $journeyPathId ${_reach(run.reach)} -> ${_decision(decision)}',
  Returned(:final journeyPathId, :final run, :final outcome) =>
    'returned $journeyPathId ${_reach(run.reach)} -> ${_outcome(outcome)}',
  Narrowed(:final journeyPathId, :final child, :final rules, :final granted) =>
    'narrowed $journeyPathId -> $child rules=$rules granted=$granted',
};

String _reach(Reach reach) => switch (reach) {
  Reads(:final path) => 'reads $path',
  Writes(:final file) => 'writes ${file.path}',
  Starts(:final program, :final args) =>
    'starts $program ${args.args.join(' ')}',
};

String _decision(Decision decision) => switch (decision) {
  Allow(:final by) => 'allow (by ${by.name})',
  Deny(:final why, :final by) => 'deny (by ${by.name}): $why',
};

String _outcome(Outcome<Object?> outcome) => switch (outcome) {
  Ran() => 'ran',
  Refused(:final why) => 'refused: $why',
};
