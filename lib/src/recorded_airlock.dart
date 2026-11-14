import 'dart:convert';
import 'dart:io';
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
/// chained and checked — not policy. `P`, the host's place-in-a-turn type,
/// is never read here either: it is logged by whatever it prints as, same
/// as everything else an entry carries.
final class RecordedAirlock<R, P> implements Airlock<R, P> {
  RecordedAirlock(
    this._journal, {
    required this._decide,
    required this._narrows,
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  final Journal _journal;
  final HttpClient _client;
  final Decision Function(Run<Object?> run, R rules) _decide;
  final bool Function(R fewer, R rules) _narrows;

  @override
  Future<Decision> decide(Run<Object?> run, R rules) async =>
      _decide(run, rules);

  @override
  bool narrows(R fewer, R rules) => _narrows(fewer, rules);

  @override
  Future<void> record(Entry<P> entry) async {
    _journal.add(utf8.encode(_describe(entry)));
  }

  /// Witnesses [bytes] arriving from [source], before anything reads them:
  /// the airlock's own record of an arrival, kept in the same journal as
  /// every [Entry], an entry [Airlock.record] has no way to take — and
  /// never will: `is_airlock_api` defines no `Witnessed` entry at all,
  /// since no tool is involved and so the contract has nothing to guard.
  /// Witnessing, of arrivals and of prompts alike, is entirely this
  /// package's job.
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

  /// Sends [body] to [to], as one prompt under [pass] from [source], with
  /// [headers], and records both it and its reply. Returns the reply
  /// exactly as recorded — the airlock is the only thing that sends a
  /// prompt through it, so what a caller reads back is what the journal
  /// holds, never a second copy of the same bytes read some other way.
  ///
  /// The prompt is recorded (its headers [masked]) before anything is
  /// sent; if it can't be, nothing is sent. The reply is gathered as it
  /// arrives and recorded once its body is over, whether it completed or
  /// [ReplyFailed]. If the reply can't be recorded, the error from the
  /// journal is thrown — an answer with no record of how it arrived is
  /// not used — even though it was already received.
  ///
  /// No sender holds a connection or a recorder of its own: sending a
  /// prompt and witnessing it happen together, by construction, not by a
  /// sender remembering to call both.
  Future<ReplyRecord> prompt(
    JourneyPathId pass,
    ArrivalSource source,
    Uri to,
    Uint8List body,
    Map<String, String> headers, {
    DateTime Function()? now,
  }) async {
    final nowFn = now ?? DateTime.now;
    final promptRecord = PromptRecord(
      pass: pass,
      source: source,
      to: to,
      sent: nowFn(),
      headers: masked(headers),
      body: body,
    );
    final promptId = PromptId.of(_journal.add(promptRecord.toBytes()));

    int? status;
    var replyHeaders = const <String, List<String>>{};
    final collected = BytesBuilder(copy: true);
    ReplyEnd end;
    try {
      final request = await _client.postUrl(to);
      headers.forEach(request.headers.set);
      request.add(body);
      final response = await request.close();
      status = response.statusCode;
      final gathered = <String, List<String>>{};
      response.headers.forEach((name, values) => gathered[name] = values);
      replyHeaders = gathered;
      await for (final chunk in response) {
        collected.add(chunk);
      }
      end = const ReplyComplete();
    } on Exception catch (e) {
      end = ReplyFailed('$e');
    }

    final replyRecord = ReplyRecord(
      prompt: promptId,
      status: status,
      headers: replyHeaders,
      end: end,
      ended: nowFn(),
      body: collected.takeBytes(),
    );
    _journal.add(replyRecord.toBytes());
    return replyRecord;
  }
}

/// One journal line for [entry]. Human-readable, per `is_journal`'s own
/// design ("nothing checks it as it runs, so a person reads it instead"),
/// and, like the Teams relay's own log line, the reason a run was decided or
/// what became of it, never a copy of what it carried: no file text, no
/// program output.
String _describe<P>(Entry<P> entry) => switch (entry) {
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
  // Narrowed<R, P> carries its own R, independent of the P this switch is
  // over, which Dart's exhaustiveness checker can't bind without seeing a
  // concrete R — unreachable, since Decided/Returned/Narrowed are Entry<P>'s
  // only subtypes.
  Entry() => throw StateError('an Entry that is none of its own subtypes'),
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
