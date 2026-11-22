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

    expect(result, isA<Refused>());
    expect((result as Refused).why, contains('someone-else'));
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
}
