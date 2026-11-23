import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:test/test.dart';

final _origin = Origin.parse('https://api.example')!;

void main() {
  group('WebRequestDriverSocket, over a real Unix domain socket', () {
    late Directory directory;
    ServerSocket? server;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'web_request_driver_test',
      );
    });

    tearDown(() async {
      await server?.close();
      await directory.delete(recursive: true);
    });

    /// Binds a server that answers the one connection it accepts with
    /// [answer]'s own raw text (no trailing newline added — callers that
    /// want one include it), after draining whatever the client sent.
    /// [onRequest] fires once the request has been fully received, so a
    /// test can tell whether the driver ever reached this point.
    Future<File> serverAnswering(
      String answer, {
      void Function()? onRequest,
    }) async {
      final socket = File('${directory.path}/driver.sock');
      final address = InternetAddress(
        socket.path,
        type: InternetAddressType.unix,
      );
      final bound = await ServerSocket.bind(address, 0);
      server = bound;
      bound.listen((client) async {
        await client.drain<void>();
        onRequest?.call();
        client.add(utf8.encode(answer));
        await client.close();
      });
      return socket;
    }

    test('a driver the check refuses never sees the request', () async {
      var sawRequest = false;
      final socket = await serverAnswering(
        '',
        onRequest: () => sawRequest = true,
      );

      final result = await WebRequestDriverSocket(
        socket,
        checkDriver: (_) async => 'not the expected driver',
      ).carryOutWebRequest(Request(_origin));

      expect(result, isA<Refused>());
      expect((result as Refused).why, contains('not the expected driver'));
      expect(sawRequest, isFalse);
    });

    test('a driver the check passes carries out the request, with the check called once', () async {
      var checked = 0;
      final socket = await serverAnswering(
        '${jsonEncode(encodeOutcome(Ran(WebResponse(status: 201, created: '/v3/things')), encodeWebResponse))}\n',
      );

      final result =
          await WebRequestDriverSocket(
            socket,
            checkDriver: (_) async {
              checked++;
              return null;
            },
          ).carryOutWebRequest(
            Request(_origin, path: WebPath.parse('/v3/things')!),
          );

      expect(checked, 1);
      expect(result, isA<Ran<WebResponse>>());
      expect((result as Ran<WebResponse>).output.created, '/v3/things');
    });

    test(
      'refuses an answer from before is_effects\' own wire format',
      () async {
        final socket = await serverAnswering(
          '{"ran":{"status":201,"created":"1:abc"}}\n',
        );

        final result = await WebRequestDriverSocket(socket)
            .carryOutWebRequest(Request(_origin));

        expect(result, isA<Refused>());
        expect((result as Refused).why, contains('unreadable answer'));
      },
    );

    test('refuses when no service is listening', () async {
      final socket = File('${directory.path}/nothing.sock');

      final result = await WebRequestDriverSocket(socket)
          .carryOutWebRequest(Request(_origin));

      expect(result, isA<Refused>());
    });
  });
}
