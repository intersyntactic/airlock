import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId, UserSaid;
import 'package:is_docking_station/is_docking_station.dart';
import 'package:is_logbook/is_logbook.dart';
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:test/test.dart';

import 'logbook_service_harness.dart';

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

/// A [CarriesOutWebRequests] that hands every [Request] to [onSend] and
/// sends back whatever it returns.
final class _FakeWebDriver implements CarriesOutWebRequests {
  _FakeWebDriver(this.onSend);

  final Outcome<WebResponse> Function(Request request) onSend;

  @override
  Future<Outcome<WebResponse>> carryOutWebRequest(
    Request request,
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
  Airlock<String, int> airlock({
    Decision Function(TrajectoryId trajectory, Reach reach, String rules)? decide,
    ({String kind, ObjectId? previous, String body})? Function(EntryId id)?
    rawEntry,
    Map<ExternalSystemScheme, ({BuildsRequestsAnsweringEvents module, SignIn signIn})>?
    registryByScheme,
  }) => Airlock<String, int>(
    LogbookClient(harness.socketPath),
    decide: decide ?? (trajectory, reach, rules) => const Allow(by: DecidedBy.rules),
    entryOn: (trajectory, entry) async => entry == modelProposalId
        ? Ran((kind: ActionProposedByAgentLoop.kind, body: modelProposalBody))
        : Ran((kind: outcomeOfProposedActionKind, body: resultBody)),
    rawEntry: rawEntry ?? (id) => null,
    registryByScheme: registryByScheme ?? const {},
  );

  /// A trajectory on [a], with one [_FakeFileDriver] and one
  /// [_FakeWebDriver] sending back [onSend], good for driving a real run
  /// through `_consider` so the library itself produces a real result
  /// (whose constructor this package can no longer call directly).
  Trajectory<String, int> path(
    Airlock<String, int> a, {
    String rules = 'rules',
    Outcome<WebResponse> Function(Request request)? onSend,
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

    await run.next(path(a).at(1));

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
        path(
          allowed,
          onSend: (r) => const Ran(WebResponse(status: 201)),
        ).at(1),
      );
      await send(null).next(path(denied).at(2));

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
        path(
          a,
          onSend: (r) =>
              const Ran(WebResponse(status: 201, created: 'abc-123')),
        ).at(1),
      );
      await send().next(
        path(a, onSend: (r) => const Ran(WebResponse(status: 201))).at(2),
      );
      await send().next(
        path(
          a,
          onSend: (r) => const Ran(
            WebResponse(status: 400, refusedBecause: 'error.code'),
          ),
        ).at(3),
      );

      final resultLines = _entries(
        harness.journalDir,
      ).map(utf8.decode).where((l) => l.startsWith('result\n'));
      final humanLines = resultLines
          .map((l) => JsonObject.decode(l.substring(l.indexOf('{'))))
          .map((body) => body.string('line'))
          .toList();
      expect(humanLines, contains(endsWith('-> ran created=abc-123')));
      expect(humanLines, contains(endsWith('-> ran')));
      expect(humanLines, contains(endsWith('-> ran refusedBecause=error.code')));
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
        path(
          a,
          onSend: (r) => Ran(
            WebResponse(
              status: 200,
              body: const TextBody('hello'),
              redirects: [redirectedTo],
            ),
          ),
        ).at(1),
      );

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      final resultLine = lines.firstWhere((l) => l.startsWith('result\n'));
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
          'place': [0, 1],
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

  group('replyRequests and trajectoryOpenedRequests', () {
    MessageSaid messageSaid(String scheme) => MessageSaid(
      addressInExternalSystem: AddressInExternalSystem.parse(
        '$scheme:19:abc@thread.v2',
      )!,
      containingAddress: null,
      addressedTo: null,
      key: EventKey.parse('msg-1')!,
      node: UserSaid(
        author: ActorId.parse('teams:tenant-1/user-1')!,
        source: SourceMessageId.parse('msg-1')!,
        text: 'hello',
      ),
    );

    // The bytes the logbook actually hashes an admission entry's id from:
    // is_logbook 0.2.1's own wire, `<kind>\n<previous-hex-or-dash>\n<body>`
    // (is_logbook's lib/service.dart's `_append`) — the same bytes
    // [Airlock]'s own `_turnStartingAdmission` rebuilds.
    Uint8List admissionEntryBytes(
      EventAdmittedToMission admission, {
      ObjectId? previous,
    }) {
      final (kind, body) = encodeDecision(admission);
      return Uint8List.fromList([
        ...utf8.encode('$kind\n${previous?.hex ?? '-'}\n'),
        ...body,
      ]);
    }

    ({String kind, ObjectId? previous, String body}) rawOf(
      Uint8List entryBytes,
    ) {
      final text = utf8.decode(entryBytes);
      final firstBreak = text.indexOf('\n');
      final secondBreak = text.indexOf('\n', firstBreak + 1);
      return (
        kind: text.substring(0, firstBreak),
        previous: null,
        body: text.substring(secondBreak + 1),
      );
    }

    ({String kind, ObjectId? previous, String body}) relayedEventEntry(
      Uint8List bytes,
    ) => (
      kind: 'event',
      previous: null,
      body: jsonEncode({
        'at': DateTime.now().toUtc().toIso8601String(),
        'source': 'teams',
        'bytes': base64Encode(bytes),
      }),
    );

    test(
      'trajectoryOpenedRequests reads the opening admission by its own '
      'hash, decodes the relayed event, and hands both to the address '
      "scheme's module",
      () async {
        final eventEntryId = EntryId.of(utf8.encode('relayed-event-fixture'));
        final relayedBytes = utf8.encode('{"fake":"activity"}');
        final relayed = relayedEventEntry(relayedBytes);

        final admission = EventAdmittedToMission(
          ObjectId.parse(eventEntryId.hex)!,
          by: DecidedBy.rules,
          reading: messageSaid('teams'),
          placement: const StartsTrajectory(StartsMission()),
          rules: JsonObject.of({'ok': true}),
          startsTurn: true,
        );
        final entryBytes = admissionEntryBytes(admission);
        final trajectory = TrajectoryId.of(entryBytes);
        final admissionEntryId = EntryId.of(entryBytes);
        final raw = rawOf(entryBytes);

        Uint8List? capturedRelayedEvent;
        SignIn? capturedSignIn;
        final module = _FakeAnsweringModule(
          onOpened: (relayedEvent, signIn) {
            capturedRelayedEvent = relayedEvent;
            capturedSignIn = signIn;
            return [Request(Origin.parse('https://example.test')!, signIn: signIn)];
          },
        );

        final a = airlock(
          rawEntry: (id) => switch (id.hex) {
            final hex when hex == admissionEntryId.hex => raw,
            final hex when hex == eventEntryId.hex => relayed,
            _ => null,
          },
          registryByScheme: {
            ExternalSystemScheme.parse('teams')!: (
              module: module,
              signIn: SignIn.parse('cam-teams')!,
            ),
          },
        );

        switch (await a.trajectoryOpenedRequests(trajectory)) {
          case Refused(:final why):
            fail('expected Ran, got Refused: $why');
          case Ran(output: final requests):
            expect(requests, hasLength(1));
        }
        expect(capturedRelayedEvent, relayedBytes);
        expect(capturedSignIn, SignIn.parse('cam-teams'));
      },
    );

    test(
      'replyRequests reads a later-turn admission by its explicit '
      'trajectory field, with no hash to rebuild',
      () async {
        final trajectory = _id('turn-1-starts-this-trajectory');
        final eventEntryId = EntryId.of(utf8.encode('relayed-event-fixture-2'));
        final relayedBytes = utf8.encode('{"fake":"activity-2"}');
        final respondsTo = EntryId.of(utf8.encode('turn-2-admission'));

        final admission = EventAdmittedToMission(
          ObjectId.parse(eventEntryId.hex)!,
          by: DecidedBy.rules,
          reading: messageSaid('teams'),
          placement: OnTrajectory(trajectory),
          startsTurn: true,
        );
        final (kind, body) = encodeDecision(admission);

        var called = false;
        final module = _FakeAnsweringModule(
          onReply: (relayedEvent, signIn) {
            called = true;
            return [Request(Origin.parse('https://example.test')!, signIn: signIn)];
          },
        );

        final a = airlock(
          rawEntry: (id) => switch (id.hex) {
            final hex when hex == respondsTo.hex =>
              (kind: kind.toString(), previous: null, body: utf8.decode(body)),
            final hex when hex == eventEntryId.hex =>
              relayedEventEntry(relayedBytes),
            _ => null,
          },
          registryByScheme: {
            ExternalSystemScheme.parse('teams')!: (
              module: module,
              signIn: SignIn.parse('cam-teams')!,
            ),
          },
        );

        final reply = const FinishedReply(text: 'a reply');
        switch (await a.replyRequests(trajectory, respondsTo, reply)) {
          case Refused(:final why):
            fail('expected Ran, got Refused: $why');
          case Ran(output: final requests):
            expect(requests, hasLength(1));
        }
        expect(called, isTrue);
      },
    );

    test('replyRequests refuses when respondsTo is not in the logbook', () async {
      final a = airlock(rawEntry: (id) => null);
      switch (await a.replyRequests(
        _id('some-trajectory'),
        EntryId.of(utf8.encode('nowhere')),
        const FinishedReply(text: 'a reply'),
      )) {
        case Ran():
          fail('expected Refused');
        case Refused(:final why):
          expect(why, contains('not in the logbook'));
      }
    });

    test(
      'replyRequests refuses an admission that is on another trajectory',
      () async {
        final admittedTrajectory = _id('the-right-trajectory');
        final askedAbout = _id('a-different-trajectory');
        final respondsTo = EntryId.of(utf8.encode('turn-2-admission'));
        final admission = EventAdmittedToMission(
          ObjectId.of(utf8.encode('relayed-event-fixture-3')),
          by: DecidedBy.rules,
          reading: messageSaid('teams'),
          placement: OnTrajectory(admittedTrajectory),
          startsTurn: true,
        );
        final (kind, body) = encodeDecision(admission);

        final a = airlock(
          rawEntry: (id) => id.hex == respondsTo.hex
              ? (kind: kind.toString(), previous: null, body: utf8.decode(body))
              : null,
        );

        switch (await a.replyRequests(
          askedAbout,
          respondsTo,
          const FinishedReply(text: 'a reply'),
        )) {
          case Ran():
            fail('expected Refused');
          case Refused(:final why):
            expect(why, contains('does not admit an event on'));
        }
      },
    );
  });
}

/// A [BuildsRequestsAnsweringEvents] that hands whichever call it gets to
/// [onReply] or [onOpened], so a test can inspect exactly what it was given
/// and choose what it builds back.
final class _FakeAnsweringModule implements BuildsRequestsAnsweringEvents {
  _FakeAnsweringModule({this.onReply, this.onOpened});

  final List<Request>? Function(Uint8List relayedEvent, SignIn signIn)?
  onReply;
  final List<Request>? Function(Uint8List relayedEvent, SignIn signIn)?
  onOpened;

  @override
  List<Request>? replyRequests({
    required Uint8List relayedEvent,
    required ModelReply reply,
    required SignIn signIn,
  }) => onReply?.call(relayedEvent, signIn);

  @override
  List<Request>? trajectoryOpenedRequests({
    required Uint8List relayedEvent,
    required SignIn signIn,
  }) => onOpened?.call(relayedEvent, signIn);
}
