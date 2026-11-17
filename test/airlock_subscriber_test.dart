import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_shapes/is_shapes.dart' show MissionId;
import 'package:test/test.dart';

import 'logbook_service_harness.dart';

/// The bytes of every entry the harness's logbook holds, in order — the
/// same reading [recorded_airlock_test.dart] uses, duplicated here rather
/// than shared since each test file's `main` owns its own fixtures.
List<Uint8List> _entries(Directory journalDir) {
  final bytes = File('${journalDir.path}/entries').readAsBytesSync();
  return [
    for (var i = 0; i + 96 <= bytes.length; i += 96)
      _object(journalDir, Uint8List.sublistView(bytes, i + 64, i + 96)),
  ];
}

Uint8List _object(Directory journalDir, Uint8List digest) {
  final id = ObjectId.fromDigest(digest)!;
  final file = File(
    '${journalDir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
  );
  return file.readAsBytesSync();
}

/// [write]'s id, or fails the test with its refusal. [AlreadyRecorded]
/// counts as written, same as [RecordClient.send] treats it.
ObjectId _written(WriteResult result) => switch (result) {
  Written(:final entry) || AlreadyRecorded(:final entry) => entry,
  _ => throw StateError('not written: $result'),
};

/// This process's own real uid — the one the logbook service's socket
/// actually sees from a write this process makes, whatever `uidOf` says.
final _realUid = int.parse(
  Process.runSync('id', ['-u']).stdout.toString().trim(),
);

final _rulesJson = {
  'modelSignInsCallsMayGoOutAs': <String>[],
  'sitesTheWebDriverMayReach': <Object?>[],
  'programsNetwork': 'noNetworkOfTheirOwn',
};

/// Writes docking_station's admitted entry and loop_launcher's assigned
/// entry through [writer], under [rules] (`_rulesJson`'s shape, by default
/// granting nothing). Returns the trajectory's id and the assigned entry's
/// hash — the chain's tip so far, for whatever is written on it next.
Future<(TrajectoryId, ObjectId)> _admitAndAssign(
  LogbookWriter writer, {
  Map<String, Object?>? rules,
}) async {
  const admittedKind = 'event-admitted-to-mission';
  final admittedBody = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'event': ObjectId.of(utf8.encode('fake event')).hex,
        'by': 'rules',
        'reading': {'case': 'something-else'},
        'startsMission': true,
        'startsTrajectory': true,
        'rules': rules ?? _rulesJson,
      }),
    ),
  );
  final admittedObject = Uint8List.fromList([
    ...utf8.encode('$admittedKind\n-\n'),
    ...admittedBody,
  ]);
  final trajectoryId = TrajectoryId.of(admittedObject);
  await writer.write(Kind.parse(admittedKind)!, admittedBody);

  final assignedHash = _written(
    await writer.write(
      Kind.parse('users-assigned-to-trajectory')!,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'trajectory': trajectoryId.hex,
            'mission': MissionId.of(admittedObject).hex,
            'loopUser': 'loop-1',
            'suit': 'suit-1',
          }),
        ),
      ),
    ),
  );
  return (trajectoryId, assignedHash);
}

/// Writes an admitted+assigned trajectory, then an agent loop's proposed
/// read on its chain, through [writer] — exactly the three records
/// [runAirlockService] needs to decide something. Returns the proposed
/// entry's own [EntryId] (`Trajectory.consider`'s and
/// [readResultOfActionOrWhyRefused]'s `proposed` space — `EntryId.of` its
/// object bytes, header included: the same sha256 `write()`'s own
/// [ObjectId] is, under is_airlock_api's own type).
Future<EntryId> _propose(LogbookWriter writer) async {
  final (_, assignedHash) = await _admitAndAssign(writer);

  final proposedBody = Uint8List.fromList(
    utf8.encode(jsonEncode({'program': 'read', 'place': 1, 'input': ''})),
  );
  await writer.write(
    Kind.parse(ActionProposedByAgentLoop.kind)!,
    proposedBody,
    previous: assignedHash,
  );
  return EntryId.of(
    Uint8List.fromList([
      ...utf8.encode('${ActionProposedByAgentLoop.kind}\n${assignedHash.hex}\n'),
      ...proposedBody,
    ]),
  );
}

/// [proposedId]'s answer, if any of [harness]'s entries already carry one;
/// waits up to [timeout] (polling every 20ms), rather than for a listener
/// end `runAirlockService` never reaches.
Future<({EntryId proposed, Object? result})?> _awaitAnswer(
  LogbookServiceHarness harness,
  EntryId proposedId, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final bytes in _entries(harness.journalDir)) {
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!text.startsWith('$resultOfActionOrWhyRefusedKind\n')) continue;
      final body = text.substring(
        text.indexOf('\n', resultOfActionOrWhyRefusedKind.length + 1) + 1,
      );
      final decoded = readResultOfActionOrWhyRefused(jsonDecode(body));
      if (decoded != null && decoded.proposed.hex == proposedId.hex) {
        return decoded;
      }
    }
  }
  return null;
}

void main() {
  late LogbookServiceHarness harness;

  setUp(() async {
    harness = await LogbookServiceHarness.start(
      [
        'event-admitted-to-mission',
        'users-assigned-to-trajectory',
        'action-proposed-by-agent-loop',
        'airlock-decision-on-action',
        'airlock-decision-on-web-request',
        'result-of-action-or-why-refused',
      ],
      withReadSocket: true,
      // loop-1 must resolve to this test process's own real uid: the
      // logbook's chain-ownership check (`trajectory.loopUser != uid`)
      // compares the recorded loopUser against the socket's real peer
      // uid, which nothing in this process can spoof — a made-up uid
      // for loop-1 would make every write past the assigned entry
      // 'not-owner'. suit-1 only needs to differ from it.
      uidOf: (user) => switch (user) {
        'loop-1' => _realUid,
        'suit-1' => _realUid + 1,
        _ => null,
      },
    );
  });

  tearDown(() async {
    await harness.stop();
  });

  test(
    'builds a trajectory from admitted+assigned and answers a proposed read',
    () async {
      final proposedId = await _propose(LogbookWriter(harness.socketPath));

      final recordIndex = RecordIndex();
      final airlock = RecordedAirlock<WhatMayLeaveThisMachine, Place>(
        RecordClient(harness.socketPath),
        decide: (reach, rules) => const Allow(by: DecidedBy.rules),
        recordedOn: recordIndex.recordedOn,
        placeToJson: (place) => place,
      );

      unawaited(
        runAirlockService(
          subscribe: () => LogbookReader(harness.readSocketPath!).subscribe(),
          airlock: airlock,
          drivers: const [],
          proposalsEnabled: true,
          recordIndex: recordIndex,
          recordRejection: airlock.recordRejection,
          say: (_) {},
        ),
      );

      final answer = await _awaitAnswer(harness, proposedId);
      expect(answer, isNotNull, reason: 'no answer within 2s');
      final outcome = decodeOutcome(
        answer!.result,
        (json, field) => decodeReadResult(json, field),
      );
      // No real ReadsAndWritesFiles driver is wired tonight (drivers: const
      // []): the proposal is still decided, recorded and answered, but with
      // nothing able to carry it out.
      expect(outcome, isA<Refused>());
    },
  );

  test(
    'proposalsEnabled: false ignores a proposed entry outright (task 20)',
    () async {
      final proposedId = await _propose(LogbookWriter(harness.socketPath));

      final recordIndex = RecordIndex();
      final airlock = RecordedAirlock<WhatMayLeaveThisMachine, Place>(
        RecordClient(harness.socketPath),
        decide: (reach, rules) => const Allow(by: DecidedBy.rules),
        recordedOn: recordIndex.recordedOn,
        placeToJson: (place) => place,
      );

      unawaited(
        runAirlockService(
          subscribe: () => LogbookReader(harness.readSocketPath!).subscribe(),
          airlock: airlock,
          drivers: const [],
          proposalsEnabled: false,
          recordIndex: recordIndex,
          recordRejection: airlock.recordRejection,
          say: (_) {},
        ),
      );

      final answer = await _awaitAnswer(
        harness,
        proposedId,
        timeout: const Duration(milliseconds: 500),
      );
      expect(answer, isNull, reason: 'the gate should have refused to act');
    },
  );
}
