import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:test/test.dart';

/// An [AsksTheModel] that answers every call the same way, so a test can
/// tell which fake a dispatched call actually reached.
final class _FakeDriver implements AsksTheModel {
  _FakeDriver(this.reply);

  final String reply;
  ModelSignInName? calledAs;

  @override
  Future<Outcome<ModelReply>> askTheModel(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    calledAs = signIn;
    return Ran(FinishedReply(text: reply));
  }
}

ModelSignInName _signIn(String name) => ModelSignInName.parse(name)!;

void main() {
  test('dispatches a call to the driver its sign-in names', () async {
    final claude = _FakeDriver('from claude');
    final chatGpt = _FakeDriver('from chat-gpt');
    final router = RoutesModelCallsBySignIn({
      _signIn('nick-claude-team'): claude,
      _signIn('cam-chatgpt'): chatGpt,
    });

    final result = await router.askTheModel(
      _signIn('cam-chatgpt'),
      ModelName.parse('some-model')!,
      'system',
      'request',
      report: (_) {},
    );

    expect(result, isA<Ran<ModelReply>>());
    expect((result as Ran<ModelReply>).output, isA<FinishedReply>());
    expect((result.output as FinishedReply).text, 'from chat-gpt');
    expect(chatGpt.calledAs, _signIn('cam-chatgpt'));
    expect(claude.calledAs, isNull);
  });

  test('refuses a sign-in the map holds no driver for', () async {
    final claude = _FakeDriver('from claude');
    final router = RoutesModelCallsBySignIn({_signIn('nick-claude-team'): claude});

    final result = await router.askTheModel(
      _signIn('someone-else'),
      ModelName.parse('some-model')!,
      'system',
      'request',
      report: (_) {},
    );

    expect(result, isA<NothingRan>());
    expect((result as NothingRan).why, contains('someone-else'));
    expect(claude.calledAs, isNull);
  });

  group('modelDriversBySignIn', () {
    test('reads a sign-in -> {socket, user} map', () {
      final drivers = modelDriversBySignIn(
        '{"nick-claude-team": {"socket": "/run/a.sock", "user": "a"}, '
        '"cam-chatgpt": {"socket": "/run/b.sock", "user": "b"}}',
      );

      expect(drivers, {
        _signIn('nick-claude-team'): (socket: '/run/a.sock', user: 'a'),
        _signIn('cam-chatgpt'): (socket: '/run/b.sock', user: 'b'),
      });
    });

    test('refuses a key that is not a sign-in name', () {
      expect(
        () => modelDriversBySignIn(
          '{"NOT VALID": {"socket": "/run/a.sock", "user": "a"}}',
        ),
        throwsFormatException,
      );
    });

    test('refuses an entry that is not an object', () {
      expect(
        () => modelDriversBySignIn('{"nick-claude-team": "/run/a.sock"}'),
        throwsFormatException,
      );
    });

    test('refuses an entry missing socket or user', () {
      expect(
        () => modelDriversBySignIn('{"nick-claude-team": {"socket": "/run/a.sock"}}'),
        throwsFormatException,
      );
      expect(
        () => modelDriversBySignIn('{"nick-claude-team": {"user": "a"}}'),
        throwsFormatException,
      );
    });
  });

  group('RoutesModelCallsBySignIn.fromSocketsFile', () {
    test('refuses a user that names no real user, by name or id', () {
      expect(
        () => RoutesModelCallsBySignIn.fromSocketsFile(
          '{"nick-claude-team": {"socket": "/run/a.sock", "user": "-no-such-flag"}}',
        ),
        throwsFormatException,
      );
    });
  });

  group('ModelDriverSocket, over a real Unix domain socket', () {
    late Directory directory;
    late ServerSocket server;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('model_driver_test');
    });

    tearDown(() async {
      await server.close();
      await directory.delete(recursive: true);
    });

    /// Binds a server that answers the one connection it accepts by
    /// writing [lines], each already JSON-encoded, one per `\n`-terminated
    /// write — mirroring a real driver streaming its messages rather than
    /// sending them all in one chunk, so a client that buffers before
    /// reading anything (as [ModelDriverSocket] must not) would see
    /// [onReport] arrive late, if ever.
    Future<File> serverWriting(List<String> lines, {void Function()? onReport}) async {
      final socket = File('${directory.path}/driver.sock');
      final address = InternetAddress(socket.path, type: InternetAddressType.unix);
      server = await ServerSocket.bind(address, 0);
      server.listen((client) async {
        await client.drain<void>();
        for (final line in lines) {
          client.add(utf8.encode('$line\n'));
          if (line.contains('"reported"')) onReport?.call();
          await Future<void>.delayed(Duration.zero);
        }
        await client.close();
      });
      return socket;
    }

    test('reports progress as it streams, before returning the outcome', () async {
      final reportedBeforeReturn = Completer<bool>();
      var reported = false;
      final socket = await serverWriting([
        jsonEncode(
          encodeProgramMessage(
            Reported<ModelReply>(const ReplyArriving('partial')),
            encodeModelReply,
          ),
        ),
        jsonEncode(
          encodeProgramMessage(
            Finished<ModelReply>(Ran(FinishedReply(text: 'done'))),
            encodeModelReply,
          ),
        ),
      ], onReport: () => reported = true);

      final result = await ModelDriverSocket(socket).askTheModel(
        _signIn('nick-claude-team'),
        ModelName.parse('some-model')!,
        'system',
        'request',
        report: (progress) {
          reportedBeforeReturn.complete(progress is ReplyArriving);
        },
      );

      expect(await reportedBeforeReturn.future, isTrue);
      expect(reported, isTrue);
      expect(result, isA<Ran<ModelReply>>());
      expect((result as Ran<ModelReply>).output, isA<FinishedReply>());
      expect((result.output as FinishedReply).text, 'done');
    });

    test('refuses without connecting the call through when checkDriver objects', () async {
      var calledCheckDriver = false;
      final socket = await serverWriting([]);

      final result = await ModelDriverSocket(
        socket,
        checkDriver: (driver) async {
          calledCheckDriver = true;
          return 'not the expected driver';
        },
      ).askTheModel(
        _signIn('nick-claude-team'),
        ModelName.parse('some-model')!,
        'system',
        'request',
        report: (_) {},
      );

      expect(calledCheckDriver, isTrue);
      expect(result, isA<NothingRan>());
      expect((result as NothingRan).why, contains('not the expected driver'));
    });

    test(
      'an unreadable answer is StoppedPartway with done: null, since the '
      'call may already have gone out',
      () async {
        final socket = await serverWriting(['not json']);

        final result = await ModelDriverSocket(socket).askTheModel(
          _signIn('nick-claude-team'),
          ModelName.parse('some-model')!,
          'system',
          'request',
          report: (_) {},
        );

        expect(result, isA<StoppedPartway<ModelReply>>());
        final stopped = result as StoppedPartway<ModelReply>;
        expect(stopped.done, isNull);
        expect(stopped.why, contains('unreadable answer'));
        expect(stopped.why, contains('not json'));
      },
    );
  });
}
