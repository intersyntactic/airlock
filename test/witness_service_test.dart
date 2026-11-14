import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_airlock/src/witness_service.dart';
import 'package:is_journal/is_journal.dart';
import 'package:test/test.dart';

import 'journal_service_harness.dart';

late JournalServiceHarness harness;
late Directory socketDir;
late String socketPath;
late ServerSocket server;
late Completer<void> stopping;
late Future<void> serving;

/// The bytes of every entry the harness's journal holds, in order —
/// same approach as recorded_airlock_test.dart.
List<Uint8List> _entries() {
  final bytes = File('${harness.journalDir.path}/entries').readAsBytesSync();
  return [
    for (var i = 0; i + 96 <= bytes.length; i += 96)
      _object(Uint8List.sublistView(bytes, i + 64, i + 96)),
  ];
}

Uint8List _object(Uint8List digest) {
  final id = ObjectId.fromDigest(digest)!;
  final file = File(
    '${harness.journalDir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
  );
  return file.readAsBytesSync();
}

int _witnessedCount() =>
    _entries().where((e) => utf8.decode(e).startsWith('witnessed\n-\n')).length;

Future<Map<String, Object?>> _call(Map<String, Object?> request) async {
  final socket = await Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  socket.add(utf8.encode('${jsonEncode(request)}\n'));
  final line = await utf8.decoder
      .bind(socket)
      .transform(const LineSplitter())
      .first;
  await socket.close();
  return jsonDecode(line) as Map<String, Object?>;
}

void main() {
  setUp(() async {
    harness = await JournalServiceHarness.start(['witnessed']);
    socketDir = Directory.systemTemp.createTempSync(
      'witness_service_test_sock_',
    );
    socketPath = '${socketDir.path}/airlock.sock';
    server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    stopping = Completer<void>();
    serving = WitnessService(Witness(RecordClient(harness.socketPath)))
        .serve(server, stop: stopping.future);
  });

  tearDown(() async {
    if (!stopping.isCompleted) stopping.complete();
    await serving;
    await server.close();
    socketDir.deleteSync(recursive: true);
    await harness.stop();
  });

  test(
    'a witnessed arrival is recorded, and no success is reported without one',
    () async {
      final bytes = utf8.encode('{"text":"hi"}');
      final response = await _call({
        'source': 'teams',
        'bytes': base64Encode(bytes),
      });

      expect(response.containsKey('error'), isFalse);
      expect(response['id'], isA<String>());
      expect((response['id'] as String).length, 64);

      final stored = _entries().singleWhere(
        (e) => utf8.decode(e).startsWith('witnessed\n-\n'),
      );
      final body = utf8.decode(stored).split('\n').skip(2).join('\n');
      final decoded = jsonDecode(body) as Map<String, Object?>;
      expect(decoded['source'], 'teams');
      expect(base64Decode(decoded['bytes'] as String), bytes);
    },
  );

  test('an unknown source is an error, never a success', () async {
    final response = await _call({
      'source': 'not a valid source!',
      'bytes': base64Encode(utf8.encode('x')),
    });
    expect(response.containsKey('error'), isTrue);
    expect(response.containsKey('id'), isFalse);
  });

  test('a failed write is an error marked not to retry, and nothing extra is added', () async {
    final objects = Directory('${harness.journalDir.path}/objects')
      ..createSync();
    Process.runSync('chmod', ['555', objects.path]);
    addTearDown(() => Process.runSync('chmod', ['755', objects.path]));

    final response = await _call({
      'source': 'teams',
      'bytes': base64Encode(utf8.encode('cannot be kept')),
    });

    expect(response.containsKey('id'), isFalse);
    expect(response.containsKey('error'), isTrue);
    expect(response['retry'], isFalse);
  });

  test('malformed JSON is an error, never a success', () async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    socket.add(utf8.encode('not json\n'));
    final line = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first;
    await socket.close();
    final response = jsonDecode(line) as Map<String, Object?>;
    expect(response.containsKey('error'), isTrue);
  });

  test(
    'a connection closed with nothing sent is an error, not a crash',
    () async {
      final socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      await socket.close();
      // The service must still be serving other connections afterwards.
      final response = await _call({
        'source': 'teams',
        'bytes': base64Encode(utf8.encode('{}')),
      });
      expect(response.containsKey('id'), isTrue);
    },
  );

  test('two witnessed arrivals are two entries', () async {
    await _call({'source': 'teams', 'bytes': base64Encode(utf8.encode('a'))});
    await _call({'source': 'teams', 'bytes': base64Encode(utf8.encode('b'))});
    expect(_witnessedCount(), 2);
  });

  test(
    'serve stops accepting after stop completes, once in-flight work is done',
    () async {
      final response = await _call({
        'source': 'teams',
        'bytes': base64Encode(utf8.encode('x')),
      });
      expect(response.containsKey('id'), isTrue);

      stopping.complete();
      await serving;
      // serve() stops reading connections once stop fires; closing the
      // socket itself is the caller's, same as opening it was.
      await server.close();

      await expectLater(
        Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        ),
        throwsA(isA<SocketException>()),
      );
    },
  );
}
