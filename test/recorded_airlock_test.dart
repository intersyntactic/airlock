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

/// A [Run] good enough to be recorded; what it carries is never read back.
Run<Object?> _run() =>
    Program.read.run<Outcome<ReadResult>>(RelativePath.root, then: Done.new);

/// A [Run] whose reach is [Sends], as [origin] under [signIn].
Run<Object?> _send(Origin origin, {SignIn? signIn}) => Program.web
    .run<Outcome<Sent>>(Request(origin, signIn: signIn), then: Done.new);

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
      'witnessed',
      'decided',
      'returned',
    ]);
  });

  tearDown(() async {
    await harness.stop();
  });

  RecordedAirlock<String, int> airlock({
    Decision Function(Run<Object?> run, String rules)? decide,
  }) => RecordedAirlock<String, int>(
    RecordClient(harness.socketPath),
    decide: decide ?? (run, rules) => const Allow(by: DecidedBy.rules),
  );

  test('decide delegates to the rules given to it', () async {
    var decided = false;
    final a = airlock(
      decide: (run, rules) {
        decided = true;
        return const Deny('no', by: DecidedBy.person);
      },
    );

    final decision = await a.decide(_run(), 'rules');
    expect(decision, isA<Deny>());
    expect(decided, isTrue);
  });

  test('record sends one entry per Entry, naming no file text', () async {
    final a = airlock();
    final id = _id('conv-1');
    final run = _run();

    await a.record(Decided(id, 1, run, const Allow(by: DecidedBy.rules)));
    await a.record(Returned(id, 1, run, const Ran(ReadMissing())));

    final journal = Journal.open(harness.journalDir)!;
    try {
      final result = journal.check();
      expect(result, isA<Intact>());
      // The service's own `started` entry, plus the two above.
      expect((result as Intact).count, 3);
    } finally {
      journal.close();
    }
  });

  test(
    'a Decided entry for a Sends reach names the origin and sign-in',
    () async {
      final a = airlock();
      final id = _id('conv-1');
      final origin = Origin.parse('https://smba.trafficmanager.net')!;

      await a.record(
        Decided(
          id,
          1,
          _send(origin, signIn: SignIn.parse('hart-bot')),
          const Allow(by: DecidedBy.rules),
        ),
      );
      await a.record(
        Decided(
          id,
          2,
          _send(origin),
          const Deny('no sign-in', by: DecidedBy.rules),
        ),
      );

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      expect(lines, contains(contains('sends $origin as hart-bot')));
      expect(lines, contains(contains('sends $origin as no sign-in')));
      // Each is its own chain, per Nick's ruling: a decision never
      // continues another entry's chain.
      expect(lines, everyElement(contains('\n-\n')));
    },
  );

  test(
    'a Returned entry for a Sent outcome carries the created id, when there is one',
    () async {
      final a = airlock();
      final id = _id('conv-1');
      final origin = Origin.parse('https://smba.trafficmanager.net')!;
      final run = _send(origin, signIn: SignIn.parse('hart-bot'));

      await a.record(
        Returned(id, 1, run, const Ran(Sent(status: 201, created: 'abc-123'))),
      );
      await a.record(Returned(id, 2, run, const Ran(Sent(status: 201))));

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      expect(lines, contains(contains('-> ran created=abc-123')));
      expect(
        lines,
        contains(predicate<String>((l) => l.endsWith('-> ran'))),
      );
    },
  );

  test(
    'witness keeps the exact bytes it was given, with no parsing of its own',
    () async {
      final a = airlock();
      final bytes = Uint8List.fromList(utf8.encode('{"text":"hi"}'));

      final hash = await a.witness(
        bytes,
        source: ArrivalSource.parse('teams')!,
        at: DateTime.utc(2026, 11, 14),
      );

      final journal = Journal.open(harness.journalDir)!;
      final Uint8List stored;
      try {
        final found = _entries(harness.journalDir)
            .firstWhere((e) => utf8.decode(e).startsWith('witnessed\n-\n'));
        stored = found;
      } finally {
        journal.close();
      }
      expect(hash.hex.length, 64);
      final body = utf8.decode(stored).split('\n').skip(2).join('\n');
      final decoded = jsonDecode(body) as Map<String, Object?>;
      expect(decoded['source'], 'teams');
      expect(decoded['at'], '2026-11-14T00:00:00.000Z');
      expect(base64Decode(decoded['bytes'] as String), bytes);
    },
  );

  test(
    'two arrivals are two different entries, even with identical bytes',
    () async {
      final a = airlock();
      final bytes = Uint8List.fromList(utf8.encode('same'));

      final first = await a.witness(
        bytes,
        source: ArrivalSource.parse('teams')!,
      );
      final second = await a.witness(
        bytes,
        source: ArrivalSource.parse('teams')!,
      );

      expect(first, isNot(second));
    },
  );

  test('ArrivalSource refuses blank text and whitespace', () {
    expect(ArrivalSource.parse(''), isNull);
    expect(ArrivalSource.parse('teams relay'), isNull);
    expect(ArrivalSource.parse('teams').toString(), 'teams');
  });

  test('witnessing a kind the writer has not granted this user is refused, nothing recorded', () async {
    await harness.stop();
    harness = await JournalServiceHarness.start(['decided']); // no `witnessed`
    final a = airlock();

    await expectLater(
      a.witness(
        Uint8List.fromList(utf8.encode('{}')),
        source: ArrivalSource.parse('teams')!,
      ),
      throwsA(isA<RecordRefused>()),
    );
  });
}
