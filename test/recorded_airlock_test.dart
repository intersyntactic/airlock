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

/// A [Sends] reach, posting to [origin] under [signIn], with no renderer
/// resolved — enough to exercise decide/record without a real renderer.
Sends _sends(Origin origin, {SignIn? signIn}) => Sends(
  Post(origin, renderer: RendererName.parse('a-renderer')!, signIn: signIn),
  null,
);

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
  }) => RecordedAirlock<String, int>(
    RecordClient(harness.socketPath),
    decide: decide ?? (reach, rules) => const Allow(by: DecidedBy.rules),
  );

  test('decide delegates to the rules given to it', () async {
    var decided = false;
    final a = airlock(
      decide: (reach, rules) {
        decided = true;
        return const Deny('no', by: DecidedBy.person);
      },
    );

    final decision = await a.decide(
      Reads(RelativePath.root),
      'rules',
    );
    expect(decision, isA<Deny>());
    expect(decided, isTrue);
  });

  test('record sends one entry per Entry, naming no file text', () async {
    final a = airlock();
    final id = _id('conv-1');
    final reach = Reads(RelativePath.root);

    await a.record(Decided(id, 1, reach, const Allow(by: DecidedBy.rules)));
    await a.record(Returned(id, 1, reach, const Ran(ReadMissing())));

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
          _sends(origin, signIn: SignIn.parse('hart-bot')),
          const Allow(by: DecidedBy.rules),
        ),
      );
      await a.record(
        Decided(
          id,
          2,
          _sends(origin),
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
      final reach = _sends(origin, signIn: SignIn.parse('hart-bot'));

      await a.record(
        Returned(id, 1, reach, const Ran(Sent(status: 201, created: 'abc-123'))),
      );
      await a.record(Returned(id, 2, reach, const Ran(Sent(status: 201))));

      final lines = _entries(harness.journalDir).map(utf8.decode).toList();
      expect(lines, contains(contains('-> ran created=abc-123')));
      expect(
        lines,
        contains(predicate<String>((l) => l.endsWith('-> ran'))),
      );
    },
  );
}
