import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_logbook_client/is_logbook_client.dart';
import 'package:is_shapes/is_shapes.dart' show MissionId;
import 'package:test/test.dart';

import 'logbook_service_harness.dart';

/// The bytes of every entry the harness's logbook holds, in order — same
/// reading as the other test files, duplicated rather than shared since
/// each file's `main` owns its own fixtures.
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

ObjectId _written(WriteResult result) => switch (result) {
  Written(:final entry) || AlreadyRecorded(:final entry) => entry,
  WriteRefused(:final why) => throw StateError('refused: $why'),
  _ => throw StateError('not written: $result'),
};

final _rulesJson = {
  'whatMayLeaveThisMachine': {
    'modelSignInsCallsMayGoOutAs': <String>['nick-claude-team'],
    'fetchesMayReach': <Object?>[],
    'webRequestsMayReach': <Object?>[],
    'programsNetwork': 'noNetworkOfTheirOwn',
  },
  'startingModel': {'signIn': 'nick-claude-team', 'model': 'claude-opus-5-5'},
  'programsItMayRun': <String>[],
  'programsItNeeds': <String>[],
  'givenTools': <Object?>[],
};

/// `loop-1`/`suit-1` are the only loop user and suit [harness] resolves to
/// a real uid (see `uidOf` below, which the logbook's own ownership check
/// compares against this process's real peer uid) — so, to open a second
/// trajectory at all, [_close] must free the first one's before
/// [_admitAndAssign] reuses them: the logbook refuses the same loop user
/// or suit while another open trajectory already holds either.
Future<(TrajectoryId, ObjectId, MissionId)> _admitAndAssign(
  LogbookWriter writer,
  String seed,
) async {
  const admittedKind = 'event-admitted-to-mission';
  final admittedBody = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'event': ObjectId.of(utf8.encode('fake event $seed')).hex,
        'by': 'rules',
        'translatedEvent': {'case': 'something-else'},
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
  final mission = MissionId.of(admittedObject);
  await writer.write(Kind.parse(admittedKind)!, admittedBody);

  final assignedHash = _written(
    await writer.write(
      Kind.parse('users-assigned-to-trajectory')!,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'trajectory': trajectoryId.hex,
            'mission': mission.hex,
            'loopUser': 'loop-1',
            'suit': 'suit-1',
          }),
        ),
      ),
    ),
  );
  return (trajectoryId, assignedHash, mission);
}

Future<(EntryId, TrajectoryId, MissionId)> _propose(
  LogbookWriter writer,
  String seed,
) async {
  final (trajectoryId, assignedHash, mission) = await _admitAndAssign(writer, seed);
  final proposedBody = Uint8List.fromList(
    // [turn, intent, action]: the one PlaceInTrajectory shape this test
    // can build without its library-private wire tags for the other two.
    utf8.encode(jsonEncode({'program': 'read', 'place': [0, 0, 0], 'input': seed})),
  );
  await writer.write(
    Kind.parse(ActionProposedByAgentLoop.kind)!,
    proposedBody,
    previous: assignedHash,
  );
  final proposed = EntryId.of(
    Uint8List.fromList([
      ...utf8.encode('${ActionProposedByAgentLoop.kind}\n${assignedHash.hex}\n'),
      ...proposedBody,
    ]),
  );
  return (proposed, trajectoryId, mission);
}

/// Frees `loop-1`/`suit-1` for [_admitAndAssign] to reuse on a second
/// trajectory.
Future<void> _close(
  LogbookWriter writer,
  TrajectoryId trajectoryId,
  MissionId mission,
) async {
  await writer.write(
    Kind.trajectoryClosed,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'by': 'person',
          'trajectory': trajectoryId.hex,
          'mission': mission.hex,
          'operator': 'nick',
          'reason': 'test',
        }),
      ),
    ),
  );
}

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
      final decoded = readOutcomeOfProposedAction(body);
      if (decoded != null && decoded.proposed.hex == proposedId.hex) {
        return decoded;
      }
    }
  }
  return null;
}

void main() {
  late LogbookServiceHarness harness;
  final realUid = int.parse(Process.runSync('id', ['-u']).stdout.toString().trim());

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
        'trajectory-closed',
      ],
      withReadSocket: true,
      uidOf: (user) => switch (user) {
        'loop-1' => UserId.parse(realUid),
        'suit-1' => UserId.parse(realUid + 1),
        _ => null,
      },
    );
  });

  tearDown(() async {
    await harness.stop();
  });

  test(
    'a drain signal stops new proposals from being considered, without '
    'disturbing one already answered (task 39, Nick\'s fix 24 Nov)',
    () async {
      final drain = StreamController<void>();
      final entryIndex = EntryIndex();
      final airlock = Airlock<FlightRules, PlaceInTrajectory>(
        LogbookClient(harness.socketPath),
        decide: (trajectory, reach, rules) =>
            const Allow.withNoPaths(by: DecidedBy.rules),
        entryOn: entryIndex.entryOn,
      );

      final serviceDone = runAirlockService(
        subscribe: () => LogbookReader(harness.readSocketPath!).subscribe(),
        airlock: airlock,
        drivers: const (files: null, programs: null, web: null, model: null),
        proposalsEnabled: true,
        entryIndex: entryIndex,
        writeRejection: airlock.writeRejection,
        writeLogbookEntry: airlock.writeLogbookEntry,
        say: (_) {},
        drainOn: drain.stream,
      );

      final writer = LogbookWriter(harness.socketPath);
      final (before, beforeTrajectory, beforeMission) = await _propose(
        writer,
        'before',
      );
      final beforeAnswer = await _awaitAnswer(harness, before);
      expect(beforeAnswer, isNotNull, reason: 'a proposal before draining should still answer');
      await _close(writer, beforeTrajectory, beforeMission);

      drain.add(null);
      await drain.close();
      await serviceDone.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('runAirlockService did not exit after draining'),
      );

      final (after, _, _) = await _propose(writer, 'after');
      final afterAnswer = await _awaitAnswer(
        harness,
        after,
        timeout: const Duration(milliseconds: 300),
      );
      expect(
        afterAnswer,
        isNull,
        reason: 'a proposal after draining should never be considered',
      );
    },
  );
}
