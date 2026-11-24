import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:test/test.dart';

/// A [SendsToTheLogbook] that runs [_script] one entry per call — an
/// [Exception] to throw, or an id to return — so a test can make a
/// specific call transiently fail without a real logbook.
final class _ScriptedLogbook implements SendsToTheLogbook {
  _ScriptedLogbook(this._script);

  final List<Object> _script;
  var calls = 0;

  @override
  Future<ObjectId> send(String kind, Uint8List body, {ObjectId? previous}) async {
    calls++;
    final next = _script.removeAt(0);
    if (next is Exception) throw next;
    return next as ObjectId;
  }
}

ObjectId _id(String seed) => ObjectId.of(Uint8List.fromList(seed.codeUnits));

final _trajectory = TrajectoryId.of(Uint8List.fromList('trajectory'.codeUnits));
final _decision = AirlockDecisionOnAction<int>(
  _trajectory,
  0,
  const Reads(RelativePath.root),
  const Allow.withNoPaths(by: null),
  proposed: EntryId.of(Uint8List.fromList('proposed'.codeUnits)),
);

void main() {
  group('Airlock.writeResult, retrying a failed write (task 39)', () {
    test(
      'retries a LogbookFailed write with backoff until it succeeds, '
      'without ever throwing',
      () async {
        final sleeps = <Duration>[];
        final logbook = _ScriptedLogbook([
          _id('decision'), // writeDecision's own send
          const LogbookFailed('socket unreachable'),
          const LogbookFailed('socket unreachable'),
          _id('result'), // the retry that finally lands
        ]);
        final airlock = Airlock<int, int>(
          logbook,
          decide: (trajectory, reach, rules) =>
              const Allow.withNoPaths(by: null),
          entryOn: (trajectory, entry) async =>
              Ran((kind: 'kind', body: 'body')),
          sleep: (duration) async => sleeps.add(duration),
        );

        await airlock.writeDecision(_decision);
        await airlock.writeResult(
          _decision,
          const Ran('ok'),
          resultAsJson: 'ok',
        );

        expect(logbook.calls, 4);
        expect(sleeps.length, 2);
        expect(sleeps[1] > sleeps[0], isTrue, reason: 'backoff should grow');
      },
    );

    test(
      'a LogbookRefused write is never retried — these bytes will never go '
      'in, so it propagates at once',
      () async {
        final sleeps = <Duration>[];
        final logbook = _ScriptedLogbook([
          _id('decision'),
          const LogbookRefused('malformed body'),
        ]);
        final airlock = Airlock<int, int>(
          logbook,
          decide: (trajectory, reach, rules) =>
              const Allow.withNoPaths(by: null),
          entryOn: (trajectory, entry) async =>
              Ran((kind: 'kind', body: 'body')),
          sleep: (duration) async => sleeps.add(duration),
        );

        await airlock.writeDecision(_decision);

        await expectLater(
          airlock.writeResult(_decision, const Ran('ok'), resultAsJson: 'ok'),
          throwsA(isA<LogbookRefused>()),
        );
        expect(logbook.calls, 2);
        expect(sleeps, isEmpty);
      },
    );
  });
}
