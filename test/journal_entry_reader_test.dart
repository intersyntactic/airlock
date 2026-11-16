import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock/src/record_client.dart';
import 'package:is_airlock/src/renderers.dart';
import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:test/test.dart';

import 'journal_service_harness.dart';

/// Tests [JournalEntryReader] against a real `is_journal:service` on
/// ^0.6.0 (journal-0f: published, `get <entry>` verified against the real
/// package before announcing it) — not the hand-rolled fake this file
/// used before 0.6.0 existed.
void main() {
  late JournalServiceHarness harness;

  setUp(() async {
    harness = await JournalServiceHarness.start([
      'event',
    ], withReadSocket: true);
  });

  tearDown(() async {
    await harness.stop();
  });

  test('a recorded entry is read back exactly as it was written', () async {
    final body = Uint8List.fromList(utf8.encode('{"hello":true}'));
    final hash = await RecordClient(harness.socketPath).send('event', body);
    final reader = JournalEntryReader(harness.readSocketPath!);

    final read = await reader.read(EntryId.parse(hash.hex)!);

    expect(read, isA<EntryFound>());
    final found = (read as EntryFound).bytes;
    expect(utf8.decode(found), 'event\n-\n${utf8.decode(body)}');
  });

  test('an id nothing recorded answers EntryNotRecorded', () async {
    final reader = JournalEntryReader(harness.readSocketPath!);
    final neverWritten = EntryId.of(
      Uint8List.fromList(utf8.encode('nothing here')),
    );

    final read = await reader.read(neverWritten);

    expect(read, isA<EntryNotRecorded>());
  });

  test('two entries are read back as two different, correct ids', () async {
    final client = RecordClient(harness.socketPath);
    final first = await client.send(
      'event',
      Uint8List.fromList(utf8.encode('first')),
    );
    final second = await client.send(
      'event',
      Uint8List.fromList(utf8.encode('second')),
    );
    final reader = JournalEntryReader(harness.readSocketPath!);

    final firstRead = await reader.read(EntryId.parse(first.hex)!);
    final secondRead = await reader.read(EntryId.parse(second.hex)!);

    expect(utf8.decode((firstRead as EntryFound).bytes), contains('first'));
    expect(utf8.decode((secondRead as EntryFound).bytes), contains('second'));
  });
}
