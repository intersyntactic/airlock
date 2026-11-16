import 'dart:async';
import 'dart:typed_data';

import 'package:is_airlock/src/rendered.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

/// A controllable [EntrySubscriber]: the test decides exactly what arrives
/// and when, including never.
final class _FakeSubscriber implements EntrySubscriber {
  final _controller = StreamController<SubscribedEntry>();

  void add(SubscribedEntry entry) => _controller.add(entry);

  @override
  Stream<SubscribedEntry> subscribe({required String from}) =>
      _controller.stream;
}

SubscribedEntry _rendered(
  String hash, {
  required String previous,
  Uint8List? body,
}) => SubscribedEntry(
  hash: hash,
  kind: 'rendered',
  previous: previous,
  body: body ?? Uint8List(0),
);

void main() {
  test('a Rendered from the expected renderer becomes Ran', () async {
    final subscriber = _FakeSubscriber();
    final outcomeFuture = waitForRendered(
      decidedHash: 'decided-1',
      expectedRenderer: 'teams-reply',
      subscriber: subscriber,
      timeout: const Duration(seconds: 1),
      parseRendered: (entry) =>
          const RenderedAnswer(renderedBy: 'teams-reply', body: 'hello'),
    );

    subscriber.add(_rendered('r1', previous: 'decided-1'));

    expect(await outcomeFuture, isA<Ran<String>>());
    expect((await outcomeFuture as Ran<String>).output, 'hello');
  });

  test('a Rendered reporting its own refusal becomes Refused', () async {
    final subscriber = _FakeSubscriber();
    final outcomeFuture = waitForRendered(
      decidedHash: 'decided-1',
      expectedRenderer: 'teams-reply',
      subscriber: subscriber,
      timeout: const Duration(seconds: 1),
      parseRendered: (entry) => const RenderedAnswer(
        renderedBy: 'teams-reply',
        refusal: 'a referenced entry is missing',
      ),
    );

    subscriber.add(_rendered('r1', previous: 'decided-1'));

    final outcome = await outcomeFuture;
    expect(outcome, isA<Refused>());
    expect((outcome as Refused).why, 'a referenced entry is missing');
  });

  test(
    'an entry from the wrong renderer refuses, naming both renderers',
    () async {
      final subscriber = _FakeSubscriber();
      final outcomeFuture = waitForRendered(
        decidedHash: 'decided-1',
        expectedRenderer: 'teams-reply',
        subscriber: subscriber,
        timeout: const Duration(seconds: 1),
        parseRendered: (entry) =>
            const RenderedAnswer(renderedBy: 'some-other-renderer'),
      );

      subscriber.add(_rendered('r1', previous: 'decided-1'));

      final outcome = await outcomeFuture;
      expect(outcome, isA<Refused>());
      expect((outcome as Refused).why, contains('some-other-renderer'));
      expect(outcome.why, contains('teams-reply'));
    },
  );

  test(
    'an entry of some other kind in that slot refuses, naming its kind',
    () async {
      final subscriber = _FakeSubscriber();
      final outcomeFuture = waitForRendered(
        decidedHash: 'decided-1',
        expectedRenderer: 'teams-reply',
        subscriber: subscriber,
        timeout: const Duration(seconds: 1),
        parseRendered: (entry) => null,
      );

      subscriber.add(
        SubscribedEntry(
          hash: 'x1',
          kind: 'arrived',
          previous: 'decided-1',
          body: Uint8List(0),
        ),
      );

      final outcome = await outcomeFuture;
      expect(outcome, isA<Refused>());
      expect((outcome as Refused).why, contains('arrived'));
    },
  );

  test(
    'entries naming a different previous are ignored, not treated as the answer',
    () async {
      final subscriber = _FakeSubscriber();
      final outcomeFuture = waitForRendered(
        decidedHash: 'decided-1',
        expectedRenderer: 'teams-reply',
        subscriber: subscriber,
        timeout: const Duration(seconds: 1),
        parseRendered: (entry) =>
            const RenderedAnswer(renderedBy: 'teams-reply', body: 'right'),
      );

      subscriber.add(_rendered('other', previous: 'decided-2'));
      subscriber.add(_rendered('r1', previous: 'decided-1'));

      final outcome = await outcomeFuture;
      expect(outcome, isA<Ran<String>>());
      expect((outcome as Ran<String>).output, 'right');
    },
  );

  test('nothing naming it as previous within the timeout refuses', () async {
    final subscriber = _FakeSubscriber();

    final outcome = await waitForRendered(
      decidedHash: 'decided-1',
      expectedRenderer: 'teams-reply',
      subscriber: subscriber,
      timeout: const Duration(milliseconds: 50),
      parseRendered: (entry) => null,
    );

    expect(outcome, isA<Refused>());
    expect((outcome as Refused).why, contains('decided-1'));
  });
}
