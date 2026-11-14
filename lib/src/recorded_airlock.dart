import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_journal/is_journal.dart';

import 'arrival_source.dart';
import 'prompt_recording.dart';

/// Witnesses arrivals and sends prompts into a [Journal], needing no
/// journey path's rules to do either.
///
/// What a run may do is a journey path's own business — [RecordedAirlock]
/// adds that on top of this, for whoever has rules to bring. A caller with
/// no run and no rules, such as a pipeline sending a prompt on its own
/// behalf, builds a [Witness] directly rather than inventing a policy it
/// doesn't have, which is exactly the "pose as a journey path" shape
/// Nick ruled out for prompts.
class Witness {
  Witness(this._journal, {HttpClient? client})
    : _client = client ?? (HttpClient()..autoUncompress = false);

  final Journal _journal;
  final HttpClient _client;

  /// Witnesses [bytes] arriving from [source], before anything reads them:
  /// the airlock's own record of an arrival. `is_airlock_api` defines no
  /// `Witnessed` entry at all, and never will: no tool is involved, so the
  /// contract has nothing to guard. Witnessing, of arrivals and of
  /// prompts alike, is entirely this package's job.
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
  /// [headers], and records both it and its reply. Returns the reply's own
  /// id alongside it, exactly as recorded — the airlock is the only thing
  /// that sends a prompt through it, so what a caller reads back is what
  /// the journal holds, never a second copy of the same bytes read some
  /// other way.
  ///
  /// The prompt is recorded (its headers [masked]) before anything is
  /// sent; if it can't be, nothing is sent. [headers] are sent exactly as
  /// given and recorded exactly as given, masked: no compression is
  /// negotiated unless [headers] asks for it (`Accept-Encoding` is not
  /// added here, and `autoUncompress` is off on a client this makes for
  /// itself), so the bytes on the wire, in the record, and returned are
  /// always the same bytes — not whatever this process's HTTP client
  /// would otherwise have decided to ask for or unpack.
  ///
  /// The reply is gathered as it arrives and recorded once its body is
  /// over, whether it completed or [ReplyFailed]. If the reply can't be
  /// recorded, the error from the journal is thrown — an answer with no
  /// record of how it arrived is not used — even though it was already
  /// received.
  ///
  /// No sender holds a connection or a recorder of its own: sending a
  /// prompt and witnessing it happen together, by construction, not by a
  /// sender remembering to call both.
  Future<(ObjectId, ReplyRecord)> prompt(
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
      // dart:io adds its own Accept-Encoding by default; removed so the
      // only compression asked for is what the caller's own headers ask
      // for, and the reply's bytes match what its headers say they are.
      request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
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
    final replyId = _journal.add(replyRecord.toBytes());
    return (replyId, replyRecord);
  }
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
    super.client,
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
