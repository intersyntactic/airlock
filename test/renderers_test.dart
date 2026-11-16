import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock/src/renderers.dart';
import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// An [EntryReader] over a fixed map, for entries the real journal would
/// hand back exactly as given; [EntryReader.read] on anything else answers
/// [EntryNotRecorded].
final class _FakeReader implements EntryReader {
  _FakeReader(this._byId);

  final Map<EntryId, EntryRead> _byId;

  @override
  Future<EntryRead> read(EntryId id) async =>
      _byId[id] ?? const EntryNotRecorded();
}

Renderer _renderer() => Renderer(
  RendererId.parse(
    'a' * 64, // a valid-looking sha256 hex; never checked by this class.
  )!,
  executable: ObjectId.parse('b' * 64)!,
);

void main() {
  test(
    'render reads every entry in order and hands their bytes to run',
    () async {
      final one = _bytes('one');
      final two = _bytes('two');
      final idOne = EntryId.of(one);
      final idTwo = EntryId.of(two);
      final reader = _FakeReader({
        idOne: EntryFound(one),
        idTwo: EntryFound(two),
      });
      List<Uint8List>? given;
      final renderers = RecordedRenderers(
        reader,
        (name) async => null,
        (renderer, entries) async {
          given = entries;
          return const Ran('body');
        },
      );

      final outcome = await renderers.render(_renderer(), [idOne, idTwo]);

      expect(outcome, isA<Ran<String>>());
      expect((outcome as Ran<String>).output, 'body');
      expect(given, [one, two]);
    },
  );

  test('a never-recorded entry refuses the post, naming it', () async {
    final reader = _FakeReader({});
    final id = EntryId.of(_bytes('ghost'));
    final renderers = RecordedRenderers(
      reader,
      (name) async => null,
      (renderer, entries) async => fail('run should not be reached'),
    );

    final outcome = await renderers.render(_renderer(), [id]);

    expect(outcome, isA<Refused>());
    expect((outcome as Refused).why, contains('never recorded'));
    expect(outcome.why, contains(id.toString()));
  });

  test('an unreadable entry refuses the post, naming why', () async {
    final id = EntryId.of(_bytes('hurt'));
    final reader = _FakeReader({id: const EntryUnreadable('corrupt')});
    final renderers = RecordedRenderers(
      reader,
      (name) async => null,
      (renderer, entries) async => fail('run should not be reached'),
    );

    final outcome = await renderers.render(_renderer(), [id]);

    expect(outcome, isA<Refused>());
    expect((outcome as Refused).why, contains('unreadable'));
    expect(outcome.why, contains('corrupt'));
  });

  test(
    'an entry whose bytes do not hash to the id asked for refuses the post',
    () async {
      final wrongId = EntryId.of(_bytes('not what was asked for'));
      final reader = _FakeReader({wrongId: EntryFound(_bytes('asked for'))});
      final renderers = RecordedRenderers(
        reader,
        (name) async => null,
        (renderer, entries) async => fail('run should not be reached'),
      );

      final outcome = await renderers.render(_renderer(), [wrongId]);

      expect(outcome, isA<Refused>());
      expect((outcome as Refused).why, contains('does not hash to its own id'));
    },
  );

  test('find delegates to the function given to it', () async {
    var asked = false;
    final renderers = RecordedRenderers(
      _FakeReader({}),
      (name) async {
        asked = true;
        return _renderer();
      },
      (renderer, entries) async => const Ran('unused'),
    );

    final found = await renderers.find(RendererName.parse('teams-reply')!);

    expect(found, isNotNull);
    expect(asked, isTrue);
  });
}
