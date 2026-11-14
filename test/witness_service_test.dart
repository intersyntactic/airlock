import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_airlock/src/witness_service.dart';
import 'package:is_journal/is_journal.dart';
import 'package:test/test.dart';

late Directory tmp;
late Journal journal;
late Directory socketDir;
late String socketPath;
late ServerSocket server;
late Completer<void> stopping;
late Future<void> serving;

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
    tmp = Directory.systemTemp.createTempSync('witness_service_test_');
    journal = Journal.open(Directory('${tmp.path}/journal'))!;
    socketDir = Directory('${tmp.path}/sock')..createSync();
    socketPath = '${socketDir.path}/airlock.sock';
    server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    stopping = Completer<void>();
    serving = WitnessService(Witness(journal))
        .serve(server, stop: stopping.future);
  });

  tearDown(() async {
    if (!stopping.isCompleted) stopping.complete();
    await serving;
    await server.close();
    journal.close();
    tmp.deleteSync(recursive: true);
  });

  test(
    'a witnessed arrival returns the id the journal kept it under',
    () async {
      final bytes = utf8.encode('{"text":"hi"}');
      final response = await _call({
        'source': 'teams',
        'bytes': base64Encode(bytes),
      });

      final id = response['id'] as String;
      expect(response.containsKey('error'), isFalse);
      final stored = journal.get(ObjectId.parse(id)!)!;
      final decoded = jsonDecode(utf8.decode(stored)) as Map<String, Object?>;
      final witnessed = decoded['witnessed'] as Map<String, Object?>;
      expect(witnessed['source'], 'teams');
      expect(base64Decode(witnessed['bytes'] as String), bytes);
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

  test('two witnessed arrivals are two journal entries', () async {
    await _call({'source': 'teams', 'bytes': base64Encode(utf8.encode('a'))});
    await _call({'source': 'teams', 'bytes': base64Encode(utf8.encode('b'))});
    final check = journal.check() as Intact;
    expect(check.count, 2);
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
