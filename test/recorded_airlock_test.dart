import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';
import 'package:test/test.dart';

import 'journal_service_harness.dart';

/// A journey path id, as the hash of some entry that started it. [seed]
/// stands in for that entry's bytes; this test never reads a path id back
/// to anything, so what it hashes doesn't matter, only that it's stable.
JourneyPathId _id(String seed) =>
    JourneyPathId.of(Uint8List.fromList(utf8.encode(seed)));

/// A stub [Renderer], good enough that a [Sends] reach isn't auto-denied
/// for naming none — what it actually draws is a different test's concern.
Renderer _renderer() => Renderer(
  RendererId.parse('a' * 64)!,
  executable: ObjectId.parse('b' * 64)!,
);

/// A [FileDriver] that answers every read the same way, since these tests
/// only need a real [Returned] entry to exist, not a real file.
final class _FakeFileDriver implements FileDriver {
  @override
  Future<Outcome<ReadResult>> read(RelativePath path) async =>
      const Ran(ReadMissing());

  @override
  Future<Outcome<Wrote>> write(FileText file) async =>
      const Ran(Wrote(replaced: false));
}

/// A [WebDriver] that hands every [Request] to [onSend] and sends back
/// whatever it returns.
final class _FakeWebDriver implements WebDriver {
  _FakeWebDriver(this.onSend);

  final Outcome<Sent> Function(Request request) onSend;

  @override
  Future<Outcome<Sent>> send(Request request) async => onSend(request);
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
    harness = await JournalServiceHarness.start(['decided', 'returned']);
  });

  tearDown(() async {
    await harness.stop();
  });

  RecordedAirlock<String, int> airlock({
    Decision Function(Reach reach, String rules)? decide,
    Future<Renderer?> Function(RendererName name)? renderer,
    Future<Outcome<String>> Function(Decided<int> decided)? rendered,
  }) => RecordedAirlock<String, int>(
    RecordClient(harness.socketPath),
    decide: decide ?? (reach, rules) => const Allow(by: DecidedBy.rules),
    renderer: renderer ?? (name) async => _renderer(),
    rendered: rendered ?? (decided) async => const Ran('rendered body'),
  );

  /// A journey path on [a], with one [_FakeFileDriver] and one
  /// [_FakeWebDriver] sending back [onSend], good for driving a real run
  /// through `_consider` so the library itself produces a real [Returned]
  /// (whose constructor this package can no longer call directly).
  JourneyPath<String, int> path(
    RecordedAirlock<String, int> a, {
    String rules = 'rules',
    Outcome<Sent> Function(Request request)? onSend,
  }) => JourneyPath<String, int>(
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

  test('a run records one Decided and one Returned entry', () async {
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
      // The service's own `started` entry, plus Decided and Returned.
      expect((result as Intact).count, 3);
    } finally {
      journal.close();
    }
  });

  test(
    'a Decided entry for a Sends reach names the origin and sign-in',
    () async {
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final allowed = airlock();
      final denied = airlock(
        decide: (reach, rules) => const Deny('no sign-in', by: DecidedBy.rules),
      );

      Action<Object?> send(SignIn? signIn) => Program.web.run<Outcome<Sent>>(
        Send(
          origin,
          renderer: RendererName.parse('a-renderer')!,
          signIn: signIn,
        ),
        then: Done.new,
      );

      await send(
        SignIn.parse('cam-teams'),
      ).next(path(allowed, onSend: (r) => const Ran(Sent(status: 201))).at(1));
      await send(null).next(path(denied).at(2));

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      expect(lines, contains(contains('sends $origin as cam-teams')));
      expect(lines, contains(contains('sends $origin as no sign-in')));
      // Each is its own chain, per Nick's ruling: a decision never
      // continues another entry's chain.
      expect(lines, everyElement(contains('\n-\n')));
    },
  );

  test(
    'a Returned entry for a Sent outcome carries the created id, when there is one',
    () async {
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final a = airlock();

      Action<Object?> send() => Program.web.run<Outcome<Sent>>(
        Send(
          origin,
          renderer: RendererName.parse('a-renderer')!,
          signIn: SignIn.parse('cam-teams'),
        ),
        then: Done.new,
      );

      await send().next(
        path(
          a,
          onSend: (r) => const Ran(Sent(status: 201, created: 'abc-123')),
        ).at(1),
      );
      await send().next(
        path(a, onSend: (r) => const Ran(Sent(status: 201))).at(2),
      );
      await send().next(
        path(
          a,
          onSend: (r) =>
              const Ran(Sent(status: 400, refusedBecause: 'error.code')),
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
}
