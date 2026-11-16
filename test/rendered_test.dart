import 'dart:async';
import 'dart:typed_data';

import 'package:is_airlock/src/rendered.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

/// A controllable [EntryFollower]: the test decides exactly what arrives
/// and when, including never.
final class _FakeFollower implements EntryFollower {
  final _controller = StreamController<FollowedEntry>();

  void add(FollowedEntry entry) => _controller.add(entry);

  @override
  Stream<FollowedEntry> follow({required String after}) =>
      _controller.stream;
}

FollowedEntry _rendered(
  String hash, {
  required String follows,
  Uint8List? body,
}) => FollowedEntry(
  hash: hash,
  kind: 'rendered',
  follows: follows,
  body: body ?? Uint8List(0),
);

void main() {
  test('a Rendered from the expected renderer becomes Ran', () async {
    final follower = _FakeFollower();
    final outcomeFuture = waitForRendered(
      decidedHash: 'decided-1',
      expectedRenderer: 'teams-reply',
      follower: follower,
      timeout: const Duration(seconds: 1),
      parseRendered: (entry) =>
          const RenderedAnswer(renderedBy: 'teams-reply', body: 'hello'),
    );

    follower.add(_rendered('r1', follows: 'decided-1'));

    expect(await outcomeFuture, isA<Ran<String>>());
    expect((await outcomeFuture as Ran<String>).output, 'hello');
  });

  test('a Rendered reporting its own refusal becomes Refused', () async {
    final follower = _FakeFollower();
    final outcomeFuture = waitForRendered(
      decidedHash: 'decided-1',
      expectedRenderer: 'teams-reply',
      follower: follower,
      timeout: const Duration(seconds: 1),
      parseRendered: (entry) => const RenderedAnswer(
        renderedBy: 'teams-reply',
        refusal: 'a referenced entry is missing',
      ),
    );

    follower.add(_rendered('r1', follows: 'decided-1'));

    final outcome = await outcomeFuture;
    expect(outcome, isA<Refused>());
    expect((outcome as Refused).why, 'a referenced entry is missing');
  });

  test(
    'an entry from the wrong renderer refuses, naming both renderers',
    () async {
      final follower = _FakeFollower();
      final outcomeFuture = waitForRendered(
        decidedHash: 'decided-1',
        expectedRenderer: 'teams-reply',
        follower: follower,
        timeout: const Duration(seconds: 1),
        parseRendered: (entry) =>
            const RenderedAnswer(renderedBy: 'some-other-renderer'),
      );

      follower.add(_rendered('r1', follows: 'decided-1'));

      final outcome = await outcomeFuture;
      expect(outcome, isA<Refused>());
      expect((outcome as Refused).why, contains('some-other-renderer'));
      expect(outcome.why, contains('teams-reply'));
    },
  );

  test(
    'an entry of some other kind in that slot refuses, naming its kind',
    () async {
      final follower = _FakeFollower();
      final outcomeFuture = waitForRendered(
        decidedHash: 'decided-1',
        expectedRenderer: 'teams-reply',
        follower: follower,
        timeout: const Duration(seconds: 1),
        parseRendered: (entry) => null,
      );

      follower.add(
        FollowedEntry(
          hash: 'x1',
          kind: 'arrived',
          follows: 'decided-1',
          body: Uint8List(0),
        ),
      );

      final outcome = await outcomeFuture;
      expect(outcome, isA<Refused>());
      expect((outcome as Refused).why, contains('arrived'));
    },
  );

  test(
    'entries following a different chain are ignored, not treated as the answer',
    () async {
      final follower = _FakeFollower();
      final outcomeFuture = waitForRendered(
        decidedHash: 'decided-1',
        expectedRenderer: 'teams-reply',
        follower: follower,
        timeout: const Duration(seconds: 1),
        parseRendered: (entry) =>
            const RenderedAnswer(renderedBy: 'teams-reply', body: 'right'),
      );

      follower.add(_rendered('other', follows: 'decided-2'));
      follower.add(_rendered('r1', follows: 'decided-1'));

      final outcome = await outcomeFuture;
      expect(outcome, isA<Ran<String>>());
      expect((outcome as Ran<String>).output, 'right');
    },
  );

  test('nothing following within the timeout refuses', () async {
    final follower = _FakeFollower();

    final outcome = await waitForRendered(
      decidedHash: 'decided-1',
      expectedRenderer: 'teams-reply',
      follower: follower,
      timeout: const Duration(milliseconds: 50),
      parseRendered: (entry) => null,
    );

    expect(outcome, isA<Refused>());
    expect((outcome as Refused).why, contains('decided-1'));
  });
}
