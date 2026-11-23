import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_logbook/is_logbook.dart' show Intact, ObjectId;
import 'package:test/test.dart';

import 'logbook_service_harness.dart';

/// `/`, the prefix every test here grants a web request or fetch under:
/// none of them test partial-site grants, only that a grant reaches the
/// driver at all.
final _wholeSite = PathPrefix.parse('/')!;

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
  Future<Outcome<BytesReadResult>> readBytes(RelativePath path) async =>
      const Ran(ReadMissing());

  @override
  Future<Outcome<Wrote>> write(FileText file) async =>
      const Ran(Wrote(replaced: false));
}

/// A [CarriesOutWebRequests] that hands every [GrantedRequest] to [onSend]
/// and sends back whatever it returns.
final class _FakeWebDriver implements CarriesOutWebRequests {
  _FakeWebDriver(this.onSend);

  final Outcome<WebResponse> Function(GrantedRequest request) onSend;

  @override
  Future<Outcome<WebResponse>> carryOutWebRequest(
    GrantedRequest request,
  ) async => onSend(request);
}

/// The bytes of every entry the harness's logbook holds, in order, read
/// straight from `entries` and `objects/` (documented in is_logbook's
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
  late LogbookServiceHarness harness;

  setUp(() async {
    harness = await LogbookServiceHarness.start([
      'airlock-decision-on-action',
      'airlock-decision-on-web-request',
      'outcome-of-proposed-action',
      'result',
    ]);
  });

  tearDown(() async {
    await harness.stop();
  });

  /// A fixed `outcome-of-proposed-action` entry whose result ran to
  /// [modelReplyText], answering a fixed `action-proposed-by-agent-loop`
  /// entry that asked the model: what [recordedOn] gives back regardless
  /// of which entry a test names, good enough for the tests here that
  /// care about the decision/result lines, not about proving a real
  /// chain.
  const modelReplyText = 'a reply';
  final modelProposalId = EntryId.of(utf8.encode('fake model proposal'));
  final resultBody = jsonEncode({
    'proposed': modelProposalId.hex,
    'result': {'kind': 'ran', 'output': modelReplyText},
  });
  final modelProposalBody = jsonEncode({
    'program': 'model',
    'place': [0, 0],
    'input': {
      'signIn': 'cam-teams',
      'model': 'claude',
      'request': EntryId.of(utf8.encode('fake model request')).hex,
    },
  });
  /// Grants a [FetchesFromWeb] or [MakesWebRequests] reach the whole site,
  /// under no path restriction; every other reach is allowed with no paths
  /// to grant at all, since only a web reach's grant is ever checked.
  Decision defaultDecide(TrajectoryId trajectory, Reach reach, String rules) =>
      switch (reach) {
        FetchesFromWeb() =>
          Allow(by: DecidedBy.rules, grantedPathPrefixes: [_wholeSite]),
        MakesWebRequests(:final requests) => Allow(
          by: DecidedBy.rules,
          grantedPathPrefixes: List.filled(requests.length, _wholeSite),
        ),
        _ => const Allow.withNoPaths(by: DecidedBy.rules),
      };

  Airlock<String, int> airlock({
    Decision Function(TrajectoryId trajectory, Reach reach, String rules)? decide,
  }) => Airlock<String, int>(
    LogbookClient(harness.socketPath),
    decide: decide ?? defaultDecide,
    entryOn: (trajectory, entry) async => entry == modelProposalId
        ? Ran((kind: ActionProposedByAgentLoop.kind, body: modelProposalBody))
        : Ran((kind: outcomeOfProposedActionKind, body: resultBody)),
  );

  /// A trajectory on [a], with one [_FakeFileDriver] and one
  /// [_FakeWebDriver] sending back [onSend].
  Trajectory<String, int> path(
    Airlock<String, int> a, {
    String rules = 'rules',
    Outcome<WebResponse> Function(GrantedRequest request)? onSend,
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

  /// The crux for one action at [place] on [trajectory], driving a real run
  /// through the trajectory's own `consider` — the only way to reach a
  /// result the library produces itself, since its constructor is private —
  /// by writing a made-up `action-proposed-by-agent-loop` body through
  /// [Crux.forTheModelCall] (one action per crux, matching `.at`'s old
  /// one-place-per-call shape) and reading the real outcome entry
  /// [trajectory]'s airlock wrote back for it.
  Crux at(Trajectory<String, int> trajectory, int place) =>
      Crux.forTheModelCall(_DirectLink(trajectory, place, harness), turn: place);

  test('decide delegates to the rules given to it', () async {
    var decided = false;
    final a = airlock(
      decide: (trajectory, reach, rules) {
        decided = true;
        return const Deny('no', by: DecidedBy.person);
      },
    );

    final decision = await a.decide(
      _id('conv-1'),
      Reads(RelativePath.root),
      'rules',
    );
    expect(decision, isA<Deny>());
    expect(decided, isTrue);
  });

  test('a run writes one decision and one result entry', () async {
    final a = airlock();
    final run = Program.read.run<Outcome<ReadResult>>(
      RelativePath.root,
      then: Done.new,
    );

    await run.next(at(path(a), 1));

    // Reads the same Logbook the harness's service has open — a second
    // Logbook.open on this directory, in this process, is refused.
    final result = harness.logbook.check();
    expect(result, isA<Intact>());
    // The service's own `started` entry, plus the decision and its result.
    expect((result as Intact).count, 3);
  });

  test(
    'a Decided entry for a FetchesFromWeb reach names the origin and sign-in',
    () async {
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final allowed = airlock();
      final denied = airlock(
        decide: (trajectory, reach, rules) =>
            const Deny('no sign-in', by: DecidedBy.rules),
      );

      Action<Object?> send(SignIn? signIn) =>
          Program.fetch.run<Outcome<WebResponse>>(
            WebFetch(origin, keep: BodyToKeep.none, signIn: signIn),
            then: Done.new,
          );

      await send(SignIn.parse('cam-teams')).next(
        at(
          path(allowed, onSend: (r) => const Ran(WebResponse(status: 201))),
          1,
        ),
      );
      await send(null).next(at(path(denied), 2));

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      expect(lines, contains(contains('fetches $origin as cam-teams')));
      expect(lines, contains(contains('fetches $origin as no sign-in')));
      // Each decision is its own chain, per Nick's ruling: a decision
      // never continues another entry's chain. Its result does continue
      // it, as recordResult's own doc says.
      final decisionLines = lines.where(
        (l) => l.startsWith('airlock-decision-on-action\n'),
      );
      expect(decisionLines, everyElement(contains('\n-\n')));
    },
  );

  test(
    'a Returned entry for a FetchesFromWeb outcome carries the created id, when there is one',
    () async {
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final a = airlock();

      Action<Object?> send() => Program.fetch.run<Outcome<WebResponse>>(
        WebFetch(
          origin,
          keep: BodyToKeep.none,
          signIn: SignIn.parse('cam-teams'),
        ),
        then: Done.new,
      );

      await send().next(
        at(
          path(
            a,
            onSend: (r) =>
                const Ran(WebResponse(status: 201, created: 'abc-123')),
          ),
          1,
        ),
      );
      await send().next(
        at(path(a, onSend: (r) => const Ran(WebResponse(status: 201))), 2),
      );
      await send().next(
        at(
          path(
            a,
            onSend: (r) => const Ran(
              WebResponse(status: 400, refusedBecause: 'error.code'),
            ),
          ),
          3,
        ),
      );

      final resultLines = _entries(
        harness.journalDir,
      ).map(utf8.decode).where((l) => l.startsWith('$outcomeOfProposedActionKind\n'));
      final responses = resultLines
          .map((l) => JsonObject.decode(l.substring(l.indexOf('{'))))
          .map((body) => body.object('result').object('output'))
          .toList();
      expect(
        responses,
        contains(
          predicate<JsonObject>(
            (r) =>
                r.integer('status') == 201 &&
                r.string('created') == 'abc-123',
          ),
        ),
      );
      expect(
        responses,
        contains(
          predicate<JsonObject>(
            (r) => r.integer('status') == 201 && r.stringOrNull('created') == null,
          ),
        ),
      );
      expect(
        responses,
        contains(
          predicate<JsonObject>(
            (r) =>
                r.integer('status') == 400 &&
                r.string('refusedBecause') == 'error.code',
          ),
        ),
      );
    },
  );

  test(
    'a Returned entry for a FetchesFromWeb outcome with no proposal still '
    'carries its redirects and kept body, not just the human line',
    () async {
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final a = airlock();
      final redirectedTo = RedirectedTo.of(
        Uri.parse('https://smba.trafficmanager.net/moved'),
      )!;

      Action<Object?> send() => Program.fetch.run<Outcome<WebResponse>>(
        WebFetch(
          origin,
          keep: BodyToKeep.text,
          signIn: SignIn.parse('cam-teams'),
        ),
        then: Done.new,
      );

      await send().next(
        at(
          path(
            a,
            onSend: (r) => Ran(
              WebResponse(
                status: 200,
                body: const TextBody('hello'),
                redirects: [redirectedTo],
              ),
            ),
          ),
          1,
        ),
      );

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      final resultLine = lines.firstWhere((l) => l.startsWith('$outcomeOfProposedActionKind\n'));
      final body = JsonObject.decode(resultLine.substring(resultLine.indexOf('{')));
      final output = body.object('result').object('output');
      expect(output.strings('redirects'), [redirectedTo.toString()]);
      final responseBody = output.object('body');
      expect(responseBody.string('kind'), 'text');
      expect(responseBody.string('text'), 'hello');
    },
  );

  test(
    'a result answering a proposed action is outcomeOfProposedAction, '
    'not a human line',
    () async {
      final a = airlock();
      final trajectory = path(a);
      final proposedId = EntryId.of(utf8.encode('fake proposed'));

      final received = ActionProposedByAgentLoop.read(
        jsonEncode({
          'program': 'read',
          'place': [0, 0, 1],
          'input': '',
        }),
      );
      final proposal = received as ActionProposedByAgentLoop;
      await trajectory.consider(proposal, 1, proposed: proposedId);

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      final resultLine = lines.firstWhere(
        (l) => l.contains('"proposed":"${proposedId.hex}"'),
      );
      expect(resultLine, startsWith('$outcomeOfProposedActionKind\n'));
      expect(resultLine, isNot(contains('reads')));
    },
  );

  test(
    'writeRejection answers a proposal this package never decided, same '
    'shape as a decided-and-refused result',
    () async {
      final a = airlock();
      final proposedId = EntryId.of(utf8.encode('fake proposed'));

      await a.writeRejection(proposedId, 'place: not an int');

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      final resultLine = lines.firstWhere(
        (l) => l.contains('"proposed":"${proposedId.hex}"'),
      );
      expect(resultLine, startsWith('$outcomeOfProposedActionKind\n'));
      final body = resultLine.substring(resultLine.indexOf('{'));
      final read = readOutcomeOfProposedAction(body);
      expect(read, isNotNull);
      expect(read!.proposed, proposedId);
    },
  );
}

/// Drives one action of a crux through a real [Trajectory]'s own
/// `consider`, the only way to reach a result [Airlock] produces itself
/// (its constructor is private): [writeProposal] hands the crux's own
/// `ActionProposedByAgentLoop` json straight to `consider`, tagged with a
/// made-up [EntryId] unique to this link, and [outcomeNaming] reads back
/// the real `outcome-of-proposed-action` entry the airlock wrote for it
/// out of the harness's own logbook. Good for one action — one crux is
/// built per call to [AirlockTestHelpers.at], same as `.at` fixed one
/// place per call before `Crux` existed.
final class _DirectLink implements ProposesActionsThroughTheLogbook {
  _DirectLink(this.trajectory, this.place, this.harness);

  final Trajectory<String, int> trajectory;
  final int place;
  final LogbookServiceHarness harness;

  @override
  Future<EntryId> writeProposal(String body) async {
    final proposal = ActionProposedByAgentLoop.read(body);
    if (proposal is! ActionProposedByAgentLoop) {
      throw StateError('test built an unreadable proposal: $body');
    }
    final proposed = EntryId.of(utf8.encode('direct-link-$place-$body'));
    await trajectory.consider(proposal, place, proposed: proposed);
    return proposed;
  }

  @override
  Future<String> outcomeNaming(EntryId proposed) async {
    final lines = _entries(harness.journalDir).map(utf8.decode);
    final line = lines.firstWhere(
      (l) => l.contains('"proposed":"${proposed.hex}"'),
    );
    return line.substring(line.indexOf('{'));
  }
}
