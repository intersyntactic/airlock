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

  group('socketPathsBySignIn', () {
    test('reads a sign-in -> socket path map', () {
      final paths = socketPathsBySignIn(
        '{"nick-claude-team": "/run/a.sock", "cam-chatgpt": "/run/b.sock"}',
      );

      expect(paths, {
        _signIn('nick-claude-team'): '/run/a.sock',
        _signIn('cam-chatgpt'): '/run/b.sock',
      });
    });

    test('refuses a key that is not a sign-in name', () {
      expect(
        () => socketPathsBySignIn('{"NOT VALID": "/run/a.sock"}'),
        throwsFormatException,
      );
    });

    test('refuses a value that is not a string', () {
      expect(
        () => socketPathsBySignIn('{"nick-claude-team": 1}'),
        throwsFormatException,
      );
    });
  });
}
