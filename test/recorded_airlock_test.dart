import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';
import 'package:test/test.dart';

import 'journal_service_harness.dart';

/// A trajectory id, as the hash of some entry that started it. [seed]
/// stands in for that entry's bytes; this test never reads a trajectory id
/// back to anything, so what it hashes doesn't matter, only that it's
/// stable.
TrajectoryId _id(String seed) =>
    TrajectoryId.of(Uint8List.fromList(utf8.encode(seed)));

/// A [ReadsAndWritesFiles] that answers every read the same way, since
/// these tests only need a real result entry to exist, not a real file.
final class _FakeFileDriver implements ReadsAndWritesFiles {
  @override
  Future<Outcome<ReadResult>> read(RelativePath path) async =>
      const Ran(ReadMissing());

  @override
  Future<Outcome<Wrote>> write(FileText file) async =>
      const Ran(Wrote(replaced: false));
}

/// A [CarriesOutWebRequests] that hands every [Request] to [onSend] and
/// sends back whatever it returns.
final class _FakeWebDriver implements CarriesOutWebRequests {
  _FakeWebDriver(this.onSend);

  final Outcome<WebRequestOutcome> Function(Request request) onSend;

  @override
  Future<Outcome<WebRequestOutcome>> carryOutWebRequest(
    Request request,
  ) async => onSend(request);
}

/// The bytes of every entry the harness's journal holds, in order, read
/// straight from `entries` and `objects/` (documented in is_journal's
/// README) rather than through any id this test would otherwise have to
/// track by hand. Includes the service's own `started` entry (always
/// first) and each entry's wire header (`<kind>\n<follows>\n`) ahead of
/// its body.
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

void main() {
  late JournalServiceHarness harness;

  setUp(() async {
    harness = await JournalServiceHarness.start([
      'airlock-decision-on-action',
      'airlock-decision-on-web-request',
      'result-of-action-or-why-refused',
      'result',
    ]);
  });

  tearDown(() async {
    await harness.stop();
  });

  /// What a [Projection.teamsMessageFromModelReply] web request draws its
  /// body from: a fixed `result-of-action-or-why-refused` entry whose
  /// result ran to [modelReplyText], so every such request's
  /// [MakeWebRequest] check passes regardless of which entry it names —
  /// good enough for these tests, which care about the decision/result
  /// lines, not about proving a real chain.
  const modelReplyText = 'a reply';
  final resultBody = jsonEncode({
    'proposed': EntryId.of(utf8.encode('fake proposed')).hex,
    'result': {'kind': 'ran', 'output': modelReplyText},
  });
  final teamsMessageBody = jsonEncode({
    'type': 'message',
    'text': modelReplyText,
  });

  RecordedAirlock<String, int> airlock({
    Decision Function(Reach reach, String rules)? decide,
  }) => RecordedAirlock<String, int>(
    RecordClient(harness.socketPath),
    decide: decide ?? (reach, rules) => const Allow(by: DecidedBy.rules),
    recordedOn: (trajectory, entry) async =>
        Ran((kind: resultOfActionOrWhyRefusedKind, body: resultBody)),
    placeToJson: (place) => place,
  );

  /// A trajectory on [a], with one [_FakeFileDriver] and one
  /// [_FakeWebDriver] sending back [onSend], good for driving a real run
  /// through `_consider` so the library itself produces a real result
  /// (whose constructor this package can no longer call directly).
  Trajectory<String, int> path(
    RecordedAirlock<String, int> a, {
    String rules = 'rules',
    Outcome<WebRequestOutcome> Function(Request request)? onSend,
  }) => Trajectory<String, int>(
    id: _id('conv-1'),
    drivers: [
      _FakeFileDriver(),
      _FakeWebDriver(onSend ?? (request) => const Refused('no onSend given')),
    ],
    airlock: a,
    rules: rules,
    suit: Suit.parse('suit-1')!,
  );

  test('decide delegates to the rules given to it', () async {
    var decided = false;
    final a = airlock(
      decide: (reach, rules) {
        decided = true;
        return const Deny('no', by: DecidedBy.person);
      },
    );

    final decision = await a.decide(Reads(RelativePath.root), 'rules');
    expect(decision, isA<Deny>());
    expect(decided, isTrue);
  });

  test('a run records one decision and one result entry', () async {
    final a = airlock();
    final run = Program.read.run<Outcome<ReadResult>>(
      RelativePath.root,
      then: Done.new,
    );

    await run.next(path(a).at(1));

    final journal = Journal.open(harness.journalDir)!;
    try {
      final result = journal.check();
      expect(result, isA<Intact>());
      // The service's own `started` entry, plus the decision and its result.
      expect((result as Intact).count, 3);
    } finally {
      journal.close();
    }
  });

  test(
    'a Decided entry for a MakesWebRequest reach names the origin and sign-in',
    () async {
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final allowed = airlock();
      final denied = airlock(
        decide: (reach, rules) => const Deny('no sign-in', by: DecidedBy.rules),
      );

      Action<Object?> send(SignIn? signIn) =>
          Program.web.run<Outcome<WebRequestOutcome>>(
            WebRequest(
              origin,
              body: teamsMessageBody,
              projection: Projection.teamsMessageFromModelReply,
              drawnFrom: EntryId.of(utf8.encode('fake proposed')),
              signIn: signIn,
            ),
            then: Done.new,
          );

      await send(SignIn.parse('cam-teams')).next(
        path(
          allowed,
          onSend: (r) => const Ran(WebRequestOutcome(status: 201)),
        ).at(1),
      );
      await send(null).next(path(denied).at(2));

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      expect(lines, contains(contains('sends $origin as cam-teams')));
      expect(lines, contains(contains('sends $origin as no sign-in')));
      // Each decision is its own chain, per Nick's ruling: a decision
      // never continues another entry's chain. Its result does continue
      // it, as recordResult's own doc says.
      final decisionLines = lines.where(
        (l) => l.startsWith('airlock-decision-on-web-request\n'),
      );
      expect(decisionLines, everyElement(contains('\n-\n')));
    },
  );

  test(
    'a Returned entry for a WebRequestOutcome carries the created id, when there is one',
    () async {
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final a = airlock();

      Action<Object?> send() => Program.web.run<Outcome<WebRequestOutcome>>(
        WebRequest(
          origin,
          body: teamsMessageBody,
          projection: Projection.teamsMessageFromModelReply,
          drawnFrom: EntryId.of(utf8.encode('fake proposed')),
          signIn: SignIn.parse('cam-teams'),
        ),
        then: Done.new,
      );

      await send().next(
        path(
          a,
          onSend: (r) =>
              const Ran(WebRequestOutcome(status: 201, created: 'abc-123')),
        ).at(1),
      );
      await send().next(
        path(a, onSend: (r) => const Ran(WebRequestOutcome(status: 201))).at(2),
      );
      await send().next(
        path(
          a,
          onSend: (r) => const Ran(
            WebRequestOutcome(status: 400, refusedBecause: 'error.code'),
          ),
        ).at(3),
      );

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      expect(lines, contains(contains('-> ran created=abc-123')));
      expect(
        lines,
        contains(predicate<String>((l) => l.endsWith('-> ran'))),
      );
      expect(
        lines,
        contains(contains('-> ran refusedBecause=error.code')),
      );
    },
  );

  test(
    'a result answering a proposed action is resultOfActionOrWhyRefused, '
    'not a human line',
    () async {
      final a = airlock();
      final trajectory = path(a);
      final proposedId = EntryId.of(utf8.encode('fake proposed'));

      final received = ActionProposedByAgentLoop.read({
        'program': 'read',
        'place': 1,
        'input': '',
      });
      final proposal = received as ActionProposedByAgentLoop;
      await trajectory.consider(proposal, 1, proposed: proposedId);

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      final resultLine = lines.firstWhere(
        (l) => l.contains('"proposed":"${proposedId.hex}"'),
      );
      expect(resultLine, startsWith('$resultOfActionOrWhyRefusedKind\n'));
      expect(resultLine, isNot(contains('reads')));
    },
  );
}
