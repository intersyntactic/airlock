import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_shapes/is_shapes.dart' show MissionId;
import 'package:test/test.dart';

import 'logbook_service_harness.dart';

/// Every [skippedMalformedEntryKind] line in [harness]'s record so far,
/// the same `<kind>\n<previous>\n<body>` reading [_awaitAnswer] uses for
/// [outcomeOfProposedActionKind].
List<String> _skippedEntryLines(Directory journalDir) => [
  for (final bytes in _entries(journalDir))
    utf8.decode(bytes, allowMalformed: true),
].where((text) => text.startsWith('$skippedMalformedEntryKind\n')).toList();

/// Builds one [Entry] exactly as [runAirlockService] reads it off a real
/// subscription, without going through [LogbookWriter]: the writer's own
/// schema checks refuse a malformed `event-admitted-to-mission` or
/// `users-assigned-to-trajectory` body before it is ever recorded (task
/// 38's own testing hit this), so a *historical* malformed entry — one
/// task 38 exists for — can only be exercised by handing
/// [runAirlockService] a fabricated [Entry] directly, the same shape a
/// pre-validation writer, or a bug in validation, could have left behind.
Entry _fakeEntry(String kind, ObjectId? previous, Uint8List body) {
  final recorded = Uint8List.fromList([
    ...utf8.encode('$kind\n${previous?.hex ?? '-'}\n'),
    ...body,
  ]);
  return Entry(
    id: ObjectId.of(recorded),
    kind: Kind.parse(kind)!,
    previous: previous,
    recorded: recorded,
  );
}

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
  WriteRefused(:final why) => throw StateError('refused: $why'),
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
/// [readOutcomeOfProposedAction]'s `proposed` space — `EntryId.of` its
/// object bytes, header included: the same sha256 `write()`'s own
/// [ObjectId] is, under is_airlock_api's own type).
Future<EntryId> _propose(
  LogbookWriter writer, {
  Map<String, Object?>? rules,
}) async {
  final (_, assignedHash) = await _admitAndAssign(writer, rules: rules);

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
      if (!text.startsWith('$outcomeOfProposedActionKind\n')) continue;
      final body = text.substring(
        text.indexOf('\n', outcomeOfProposedActionKind.length + 1) + 1,
      );
      final decoded = readOutcomeOfProposedAction(jsonDecode(body));
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
        'outcome-of-proposed-action',
        'skipped-malformed-entry',
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
          writeLogbookEntry: airlock.writeLogbookEntry,
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
          writeLogbookEntry: airlock.writeLogbookEntry,
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

  test(
    'an admitted entry with unreadable rules is skipped, not crashed, and '
    'the proposed entry it starves of rules is fail-closed-rejected (task 38)',
    () async {
      final admittedBody = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'event': ObjectId.of(utf8.encode('fake event')).hex,
            'by': 'rules',
            'reading': {'case': 'something-else'},
            'startsMission': true,
            'startsTrajectory': true,
            // Not a valid WhatMayLeaveThisMachine shape: readTrajectoryStart
            // reads this as UnreadableTrajectoryEntry rather than rules.
            'rules': <String, Object?>{},
          }),
        ),
      );
      final admitted = _fakeEntry(
        'event-admitted-to-mission',
        null,
        admittedBody,
      );
      final trajectoryId = TrajectoryId.of(admitted.recorded);

      final assignedBody = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'trajectory': trajectoryId.hex,
            'mission': MissionId.of(admitted.recorded).hex,
            'loopUser': 'loop-1',
            'suit': 'suit-1',
          }),
        ),
      );
      final assigned = _fakeEntry(
        'users-assigned-to-trajectory',
        null,
        assignedBody,
      );

      final proposedBody = Uint8List.fromList(
        utf8.encode(jsonEncode({'program': 'read', 'place': 1, 'input': ''})),
      );
      final proposed = _fakeEntry(
        ActionProposedByAgentLoop.kind,
        assigned.id,
        proposedBody,
      );
      final proposedId = EntryId.of(proposed.recorded);

      final recordIndex = RecordIndex();
      final airlock = RecordedAirlock<WhatMayLeaveThisMachine, Place>(
        RecordClient(harness.socketPath),
        decide: (reach, rules) => const Allow(by: DecidedBy.rules),
        recordedOn: recordIndex.recordedOn,
        placeToJson: (place) => place,
      );

      unawaited(
        runAirlockService(
          subscribe: () => Stream.fromIterable([
            admitted,
            assigned,
            proposed,
            const CaughtUp(null),
          ]),
          airlock: airlock,
          drivers: const [],
          proposalsEnabled: true,
          recordIndex: recordIndex,
          recordRejection: airlock.recordRejection,
          writeLogbookEntry: airlock.writeLogbookEntry,
          say: (_) {},
        ),
      );

      // Fail-closed-rejected (site 1, consider()'s own no-rules branch),
      // not crash-looped: the proposal still gets an answer.
      final answer = await _awaitAnswer(harness, proposedId);
      expect(answer, isNotNull, reason: 'no answer within 2s');

      // The unreadable admitted entry itself was logged (site 2), not
      // thrown past.
      expect(_skippedEntryLines(harness.journalDir), isNotEmpty);
    },
  );

  test(
    'a malformed users-assigned-to-trajectory entry is skipped, not '
    'crashed, and the service keeps serving other trajectories (task 38)',
    () async {
      // _decodeAssigned cannot read this: missing `suit`.
      final malformedAssigned = _fakeEntry(
        'users-assigned-to-trajectory',
        null,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'trajectory': TrajectoryId.of(
                utf8.encode('fake trajectory'),
              ).hex,
              'mission': MissionId.of(utf8.encode('fake mission')).hex,
              'loopUser': 'loop-1',
            }),
          ),
        ),
      );

      final recordIndex = RecordIndex();
      final airlock = RecordedAirlock<WhatMayLeaveThisMachine, Place>(
        RecordClient(harness.socketPath),
        decide: (reach, rules) => const Allow(by: DecidedBy.rules),
        recordedOn: recordIndex.recordedOn,
        placeToJson: (place) => place,
      );

      // The one fake, malformed entry first, then the real subscription —
      // so a well-formed trajectory proposed afterward through the real
      // writer reaches this same running service, proving it's still
      // alive, not just that it accepted one fake entry.
      unawaited(
        runAirlockService(
          subscribe: () async* {
            yield malformedAssigned;
            yield* LogbookReader(harness.readSocketPath!).subscribe();
          },
          airlock: airlock,
          drivers: const [],
          proposalsEnabled: true,
          recordIndex: recordIndex,
          recordRejection: airlock.recordRejection,
          writeLogbookEntry: airlock.writeLogbookEntry,
          say: (_) {},
        ),
      );

      // A well-formed trajectory proposed afterward (through the real
      // writer, since this one is well-formed) still gets answered — proof
      // the malformed assigned entry didn't kill the service.
      final writer = LogbookWriter(harness.socketPath);
      final proposedId = await _propose(writer);
      final answer = await _awaitAnswer(harness, proposedId);
      expect(answer, isNotNull, reason: 'service died after the skip');

      expect(_skippedEntryLines(harness.journalDir), isNotEmpty);
    },
  );
}
