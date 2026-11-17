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
      final writer = JournalWriter(harness.socketPath);

      // docking_station's part: admits the trajectory. Its own id is
      // `TrajectoryId.of` the entry's object bytes (header included) —
      // `is_shapes`'s hash, not the `EntryHash` `write()` returns: the two
      // are different hashes of different bytes (`EntryHash` names the
      // journal's 96-byte metadata record, not the object itself).
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

      // loop_launcher's part: hands the trajectory its users.
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

      // The agent loop's part: proposes a read, on the trajectory's own
      // chain (previous = the assigned entry that rooted it).
      final proposedBody = Uint8List.fromList(
        utf8.encode(jsonEncode({'program': 'read', 'place': 1, 'input': ''})),
      );
      await writer.write(
        Kind.parse('proposed')!,
        proposedBody,
        previous: assignedHash,
      );
      // The proposal's own identity, as `Trajectory.consider` and
      // `ReturnedProposal.proposed` name it: `EntryId.of` its object bytes
      // (header included), not the `EntryHash` `write()` returned.
      final proposedId = EntryId.of(
        Uint8List.fromList([
          ...utf8.encode('proposed\n${assignedHash.hex}\n'),
          ...proposedBody,
        ]),
      );

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
          say: (_) {},
        ),
      );

      // The service runs forever (no listener end); poll for its answer
      // rather than await it, and let tearDown's harness.stop() end it.
      ReturnedProposal? answer;
      for (var i = 0; i < 100 && answer == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (final bytes in _entries(harness.journalDir)) {
          final text = utf8.decode(bytes, allowMalformed: true);
          if (!text.startsWith('returned\n')) continue;
          final body = text.substring(text.indexOf('\n', 9) + 1);
          final decoded = ReturnedProposal.fromJson(jsonDecode(body));
          if (decoded.proposed.hex == proposedId.hex) answer = decoded;
        }
      }

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
}
