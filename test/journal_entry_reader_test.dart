import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/src/renderers.dart';
import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:test/test.dart';

/// A stand-in for is_journal's `get` read socket, answering with exactly
/// the one line this test gives it. is_journal 0.6.0 (which actually
/// serves `get`) isn't published yet, so [JournalEntryReader]'s own wire
/// parsing and hash checks — real risk, byte offsets and hashing — have
/// nothing real to run against. Replace this with the real service, the
/// way journal_service_harness.dart does for the write socket, once 0.6.0
/// is out; until then, this is what proves the parsing itself is right.
final class _FakeGetSocket {
  _FakeGetSocket._(this.socketPath, this._server, this._requests);

  final String socketPath;
  final ServerSocket _server;
  final List<String> _requests;

  List<String> get requests => _requests;

  static Future<_FakeGetSocket> start(List<int> Function(String) answer) async {
    final dir = Directory.systemTemp.createTempSync('fake_get_socket_');
    final socketPath = '${dir.path}/get.sock';
    final requests = <String>[];
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    server.listen((socket) async {
      final request = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first;
      requests.add(request);
      socket.add(answer(request));
      await socket.close();
    });
    return _FakeGetSocket._(socketPath, server, requests);
  }

  Future<void> stop() async {
    await _server.close();
    final socket = File(socketPath);
    if (socket.existsSync()) socket.deleteSync();
  }
}

/// A 96-byte journal entry record (previous│code│object, 32 bytes each),
/// and the [EntryId] it hashes to — matching is_journal's own
/// `EntryHash.of`/`JournalEntry.encode`, which is_shapes' `EntryId.of`
/// mirrors exactly.
(Uint8List record, EntryId id) _recordFor(Uint8List content) {
  final previous = List.filled(32, 0xAA);
  final code = List.filled(32, 0xBB);
  final object = ObjectId.of(content).bytes;
  final record = Uint8List.fromList([...previous, ...code, ...object]);
  return (record, EntryId.of(record));
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late _FakeGetSocket fake;

  tearDown(() async {
    await fake.stop();
  });

  test('a found entry is verified and returned', () async {
    final content = Uint8List.fromList(utf8.encode('event\n-\n{"a":1}'));
    final (record, id) = _recordFor(content);
    fake = await _FakeGetSocket.start(
      (request) => [
        ...utf8.encode('entry $id - - ${content.length} ${_hex(record)}\n'),
        ...content,
      ],
    );
    final reader = JournalEntryReader(fake.socketPath);

    final read = await reader.read(id);

    expect(read, isA<EntryFound>());
    expect((read as EntryFound).bytes, content);
    expect(fake.requests, ['get $id']);
  });

  test('a record that does not hash to the requested id is unreadable',
      () async {
    final content = Uint8List.fromList(utf8.encode('event'));
    final (record, id) = _recordFor(content);
    final tampered = Uint8List.fromList(record)..[0] = record[0] ^ 0xFF;
    fake = await _FakeGetSocket.start(
      (request) => [
        ...utf8.encode('entry $id - - ${content.length} ${_hex(tampered)}\n'),
        ...content,
      ],
    );
    final reader = JournalEntryReader(fake.socketPath);

    final read = await reader.read(id);

    expect(read, isA<EntryUnreadable>());
    expect((read as EntryUnreadable).why, contains('does not hash to'));
  });

  test(
    'content that does not hash to the record\'s own object is unreadable',
    () async {
      final content = Uint8List.fromList(utf8.encode('event'));
      final (record, id) = _recordFor(content);
      final wrongContent = Uint8List.fromList(utf8.encode('tampered'));
      fake = await _FakeGetSocket.start(
        (request) => [
          ...utf8.encode(
            'entry $id - - ${wrongContent.length} ${_hex(record)}\n',
          ),
          ...wrongContent,
        ],
      );
      final reader = JournalEntryReader(fake.socketPath);

      final read = await reader.read(id);

      expect(read, isA<EntryUnreadable>());
      expect((read as EntryUnreadable).why, contains('does not match'));
    },
  );

  test('none means the entry was never recorded', () async {
    final id = EntryId.of(Uint8List.fromList(utf8.encode('ghost')));
    fake = await _FakeGetSocket.start((request) => utf8.encode('none $id\n'));
    final reader = JournalEntryReader(fake.socketPath);

    final read = await reader.read(id);

    expect(read, isA<EntryNotRecorded>());
  });

  test('unreadable names why, missing or corrupt', () async {
    final id = EntryId.of(Uint8List.fromList(utf8.encode('hurt')));
    fake = await _FakeGetSocket.start(
      (request) => utf8.encode('unreadable $id corrupt\n'),
    );
    final reader = JournalEntryReader(fake.socketPath);

    final read = await reader.read(id);

    expect(read, isA<EntryUnreadable>());
    expect((read as EntryUnreadable).why, 'corrupt');
  });

  test('failed, refused and an incomplete answer all throw', () async {
    final id = EntryId.of(Uint8List.fromList(utf8.encode('x')));

    fake = await _FakeGetSocket.start(
      (request) => utf8.encode('failed disk error\n'),
    );
    final failedReader = JournalEntryReader(fake.socketPath);
    await expectLater(failedReader.read(id), throwsStateError);
    await fake.stop();

    fake = await _FakeGetSocket.start(
      (request) => utf8.encode('refused not-a-request\n'),
    );
    final refusedReader = JournalEntryReader(fake.socketPath);
    await expectLater(refusedReader.read(id), throwsStateError);
    await fake.stop();

    fake = await _FakeGetSocket.start((request) => utf8.encode('no newline'));
    final incompleteReader = JournalEntryReader(fake.socketPath);
    await expectLater(incompleteReader.read(id), throwsStateError);
  });
}
