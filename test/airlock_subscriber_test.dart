import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_journal_client/is_journal_client.dart';
import 'package:is_shapes/is_shapes.dart' show MissionId;
import 'package:test/test.dart';

import 'journal_service_harness.dart';

/// The bytes of every entry the harness's journal holds, in order — the
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

/// [write]'s hash, or fails the test with its refusal.
EntryHash _written(WriteResult result) => switch (result) {
  Written(:final entry) => entry,
  _ => throw StateError('not written: $result'),
};

final _rulesJson = {
  'modelSignInsCallsMayGoOutAs': <String>[],
  'sitesTheWebDriverMayReach': <Object?>[],
  'programsNetwork': 'noNetworkOfTheirOwn',
};

/// Writes docking_station's admitted entry, loop_launcher's assigned entry
/// and an agent loop's proposed read, in that order, through [writer] —
/// exactly the three records [runAirlockService] needs to decide something.
/// Returns the proposed entry's own [EntryId] (`Trajectory.consider`'s and
/// [ReturnedProposal.proposed]'s space — `EntryId.of` its object bytes,
/// header included, never the `EntryHash` `write()` returns).
Future<EntryId> _propose(JournalWriter writer) async {
  const admittedKind = 'event-admitted-to-mission';
  final admittedBody = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'event': EntryHash.of(utf8.encode('fake event')).hex,
        'by': 'rules',
        'reading': {'case': 'something-else'},
        'startsMission': true,
        'startsTrajectory': true,
        'rules': _rulesJson,
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

  final proposedBody = Uint8List.fromList(
    utf8.encode(jsonEncode({'program': 'read', 'place': 1, 'input': ''})),
  );
  await writer.write(
    Kind.parse('proposed')!,
    proposedBody,
    previous: assignedHash,
  );
  return EntryId.of(
    Uint8List.fromList([
      ...utf8.encode('proposed\n${assignedHash.hex}\n'),
      ...proposedBody,
    ]),
  );
}

/// [proposedId]'s answer, if any of [harness]'s entries already carry one;
/// waits up to [timeout] (polling every 20ms), rather than for a listener
/// end `runAirlockService` never reaches.
Future<ReturnedProposal?> _awaitAnswer(
  JournalServiceHarness harness,
  EntryId proposedId, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final bytes in _entries(harness.journalDir)) {
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!text.startsWith('returned\n')) continue;
      final body = text.substring(text.indexOf('\n', 9) + 1);
      final decoded = ReturnedProposal.fromJson(jsonDecode(body));
      if (decoded.proposed.hex == proposedId.hex) return decoded;
    }
  }
  return null;
}

void main() {
  late JournalServiceHarness harness;

  setUp(() async {
    harness = await JournalServiceHarness.start([
      'event-admitted-to-mission',
      'users-assigned-to-trajectory',
      'proposed',
      'decided',
      'returned',
    ], withReadSocket: true);
  });

  tearDown(() async {
    await harness.stop();
  });

  test(
    'builds a trajectory from admitted+assigned and answers a proposed read',
    () async {
      final proposedId = await _propose(JournalWriter(harness.socketPath));

      final airlock = RecordedAirlock<WhatMayLeaveThisMachine, Place>(
        RecordClient(harness.socketPath),
        decide: (reach, rules) => const Allow(by: DecidedBy.rules),
        renderer: (name) async => null,
        rendered: (decided) async => const Refused('n/a'),
      );

      unawaited(
        runAirlockService(
          subscribe: () => JournalReader(harness.readSocketPath!).subscribe(),
          airlock: airlock,
          drivers: const [],
          proposalsEnabled: true,
          say: (_) {},
        ),
      );

      final answer = await _awaitAnswer(harness, proposedId);
      expect(answer, isNotNull, reason: 'no answer within 2s');
      final outcome = decodeOutcome(
        answer!.outcome,
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
      final proposedId = await _propose(JournalWriter(harness.socketPath));

      final airlock = RecordedAirlock<WhatMayLeaveThisMachine, Place>(
        RecordClient(harness.socketPath),
        decide: (reach, rules) => const Allow(by: DecidedBy.rules),
        renderer: (name) async => null,
        rendered: (decided) async => const Refused('n/a'),
      );

      unawaited(
        runAirlockService(
          subscribe: () => JournalReader(harness.readSocketPath!).subscribe(),
          airlock: airlock,
          drivers: const [],
          proposalsEnabled: false,
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
