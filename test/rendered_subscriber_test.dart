import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock/src/record_client.dart';
import 'package:is_airlock/src/rendered.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_journal_client/is_journal_client.dart';
import 'package:test/test.dart';

import 'journal_service_harness.dart';

/// Tests [JournalEntrySubscriber] against a real `is_journal:service`,
/// then [waitForRendered] end to end against it — not a fake subscriber.
void main() {
  late JournalServiceHarness harness;

  setUp(() async {
    harness = await JournalServiceHarness.start([
      'decided',
      'rendered',
    ], withReadSocket: true);
  });

  tearDown(() async {
    await harness.stop();
  });

  test(
    'waitForRendered finds a real entry naming decidedHash as previous',
    () async {
      final decided = await RecordClient(harness.socketPath).send(
        'decided',
        Uint8List.fromList(utf8.encode('a decided entry')),
      );

      final outcomeFuture = waitForRendered(
        decidedHash: decided.hex,
        expectedRenderer: 'teams-reply',
        subscriber: JournalEntrySubscriber(harness.readSocketPath!),
        timeout: const Duration(seconds: 5),
        parseRendered: (entry) => entry.kind == 'rendered'
            ? const RenderedAnswer(renderedBy: 'teams-reply', body: 'hello')
            : null,
      );

      // A real subscribe reads its backlog asynchronously; give it a
      // moment to connect before the entry it's waiting for is written,
      // the same race any live subscriber has.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Writes directly with JournalWriter, naming decided as previous —
      // RecordClient never does this itself (every entry it sends starts
      // its own chain, by design), but a renderer would, so the test
      // speaks the writer's own protocol here as the renderer would.
      final written = await JournalWriter(harness.socketPath).write(
        Kind.parse('rendered')!,
        utf8.encode('a rendered body'),
        previous: EntryHash.parse(decided.hex),
      );
      expect(written, isA<Written>());

      final outcome = await outcomeFuture;
      expect(outcome, isA<Ran<String>>());
      expect((outcome as Ran<String>).output, 'hello');
    },
  );
}
