import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';
import 'package:test/test.dart';

/// A [Run] good enough to be recorded; what it carries is never read back.
Run<Object?> _run() =>
    Program.read.run<Outcome<ReadResult>>(PathInRepo.root, then: Done.new);

void main() {
  late Directory dir;
  late Journal journal;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('is_airlock_test_');
    journal = Journal.open(dir)!;
  });

  tearDown(() {
    journal.close();
    dir.deleteSync(recursive: true);
  });

  RecordedAirlock<String> airlock({
    Decision Function(Run<Object?> run, String rules)? decide,
    bool Function(String fewer, String rules)? narrows,
  }) => RecordedAirlock<String>(
    journal,
    decide: decide ?? (run, rules) => const Allow(by: DecidedBy.rules),
    narrows: narrows ?? (fewer, rules) => fewer == rules,
  );

  test('decide and narrows delegate to the rules given to it', () async {
    var decided = false;
    var narrowed = false;
    final a = airlock(
      decide: (run, rules) {
        decided = true;
        return const Deny('no', by: DecidedBy.person);
      },
      narrows: (fewer, rules) {
        narrowed = true;
        return false;
      },
    );

    final decision = await a.decide(_run(), 'rules');
    expect(decision, isA<Deny>());
    expect(decided, isTrue);

    expect(a.narrows('fewer', 'rules'), isFalse);
    expect(narrowed, isTrue);
  });

  test(
    'record keeps one journal entry per Entry, naming no file text',
    () async {
      final a = airlock();
      final id = JourneyPathId.parse('conv-1')!;
      final run = _run();

      await a.record(Decided(id, run, const Allow(by: DecidedBy.rules)));
      await a.record(Returned(id, run, const Ran(ReadMissing())));
      await a.record(
        Narrowed<String>(
          id,
          JourneyPathId.parse('conv-1/narrowed')!,
          'fewer',
          granted: true,
        ),
      );

      final check = journal.check();
      expect(check, isA<Intact>());
      expect((check as Intact).count, 3);
    },
  );

  test(
    'witness keeps the exact bytes it was given, with no parsing of its own',
    () {
      final a = airlock();
      final bytes = Uint8List.fromList(utf8.encode('{"text":"hi"}'));

      final id = a.witness(
        bytes,
        source: ArrivalSource.parse('teams')!,
        at: DateTime.utc(2026, 11, 14),
      );

      final stored = journal.get(id)!;
      final decoded = jsonDecode(utf8.decode(stored)) as Map<String, Object?>;
      final witnessed = decoded['witnessed'] as Map<String, Object?>;
      expect(witnessed['source'], 'teams');
      expect(witnessed['at'], '2026-11-14T00:00:00.000Z');
      expect(base64Decode(witnessed['bytes'] as String), bytes);
    },
  );

  test('two arrivals are two entries, even with identical bytes', () {
    final a = airlock();
    final bytes = Uint8List.fromList(utf8.encode('same'));

    a.witness(bytes, source: ArrivalSource.parse('teams')!);
    a.witness(bytes, source: ArrivalSource.parse('teams')!);

    final check = journal.check() as Intact;
    expect(check.count, 2);
  });

  test('ArrivalSource refuses blank text and whitespace', () {
    expect(ArrivalSource.parse(''), isNull);
    expect(ArrivalSource.parse('teams relay'), isNull);
    expect(ArrivalSource.parse('teams').toString(), 'teams');
  });

  test('witness on a closed journal throws, so nothing is recorded', () {
    final a = airlock();
    journal.close();

    expect(
      () => a.witness(
        Uint8List.fromList(utf8.encode('{}')),
        source: ArrivalSource.parse('teams')!,
      ),
      throwsStateError,
    );
  });
}
