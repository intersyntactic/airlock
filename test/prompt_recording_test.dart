import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal/is_journal.dart';
import 'package:test/test.dart';

late Directory tmp;
late Journal journal;

final to = Uri.parse('https://api.anthropic.com/v1/messages?beta=true');
final at = DateTime.utc(2026, 11, 10, 9, 30);
final claude = ArrivalSource.parse('claude')!;

Uint8List bytes(String s) => utf8.encode(s);

int entries(Journal j) => switch (j.check()) {
  Intact(:final count) => count,
  NoJournal() => 0,
  final Broken broken => fail('broken journal: $broken'),
};

void main() {
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prompt_recording_test_');
    journal = Journal.open(Directory('${tmp.path}/journal'))!;
  });
  tearDown(() {
    journal.close();
    tmp.deleteSync(recursive: true);
  });

  group('the records', () {
    test('a prompt reads back as it was written, its body byte for byte', () {
      // A line break in the body: only the first one, after the notes, ends them.
      final body = bytes('{"model":"m","messages":[]}\n{"second":"line"}');
      final written = PromptRecord(
        pass: 'one',
        source: claude,
        to: to,
        sent: at,
        headers: {
          'authorization': 'Bearer [masked]',
          'content-type': 'application/json',
        },
        body: body,
      ).toBytes();
      final notes = utf8.decode(written.sublist(0, written.indexOf(0x0a)));
      expect(jsonDecode(notes), {
        'kind': 'model prompt',
        'journey': 'one',
        'source': 'claude',
        'to': '$to',
        'sent': '2026-11-10T09:30:00.000Z',
        'headers': {
          'authorization': 'Bearer [masked]',
          'content-type': 'application/json',
        },
      });

      final read = PromptRecord.fromBytes(written);
      expect(read.pass, 'one');
      expect(read.source, claude);
      expect(read.to, to);
      expect(read.sent, at);
      expect(read.headers, {
        'authorization': 'Bearer [masked]',
        'content-type': 'application/json',
      });
      expect(read.body, body);
    });

    for (final end in [
      const ReplyComplete(),
      const ReplyCancelled(),
      const ReplyFailed('connection reset'),
    ]) {
      test('a reply that ended ${end.wire} reads back naming its prompt', () {
        final prompt = PromptTap(
          journal,
          'one',
          now: () => at,
        ).sending(claude, to, bytes('{}'), const {}).prompt;
        final read = ReplyRecord.fromBytes(
          ReplyRecord(
            prompt: prompt,
            status: 200,
            headers: {
              'content-type': ['text/event-stream'],
            },
            end: end,
            ended: at,
            body: bytes('event: message_start\n\n'),
          ).toBytes(),
        );
        expect(read.prompt, prompt);
        expect(read.status, 200);
        expect(read.headers, {
          'content-type': ['text/event-stream'],
        });
        expect(read.end, end);
        expect(read.ended, at);
        expect(read.body, bytes('event: message_start\n\n'));
      });
    }

    test(
      'a reply with no status leaves it out, and reads back without one',
      () {
        final prompt = PromptTap(
          journal,
          'one',
        ).sending(claude, to, bytes('{}'), const {}).prompt;
        final written = ReplyRecord(
          prompt: prompt,
          headers: const {},
          end: const ReplyFailed('refused before a status'),
          ended: at,
          body: Uint8List(0),
        ).toBytes();
        final notes = jsonDecode(
          utf8.decode(written.sublist(0, written.indexOf(0x0a))),
        ) as Map<String, Object?>;
        expect(notes.containsKey('status'), isFalse);
        expect(ReplyRecord.fromBytes(written).status, isNull);
      },
    );

    test('a reply is not read as a prompt, nor a prompt as a reply', () {
      final prompt = PromptRecord(
        pass: 'one',
        source: claude,
        to: to,
        sent: at,
        headers: const {},
        body: bytes('{}'),
      ).toBytes();
      expect(() => ReplyRecord.fromBytes(prompt), throwsFormatException);
      final tap = PromptTap(
        journal,
        'one',
      ).sending(claude, to, bytes('{}'), const {});
      final reply = ReplyRecord(
        prompt: tap.prompt,
        headers: const {},
        end: const ReplyComplete(),
        ended: at,
        body: Uint8List(0),
      ).toBytes();
      expect(() => PromptRecord.fromBytes(reply), throwsFormatException);
      expect(
        () => PromptRecord.fromBytes(bytes('no notes')),
        throwsFormatException,
      );
    });

    test('a record is read as the kind its first line says, even when its fields would fit another', () {
      final prompt = PromptRecord(
        pass: 'one',
        source: claude,
        to: to,
        sent: at,
        headers: const {},
        body: bytes('{}'),
      ).toBytes();
      final relabelled = bytes(
        utf8
            .decode(prompt)
            .replaceFirst('"kind":"model prompt"', '"kind":"model reply"'),
      );
      expect(() => PromptRecord.fromBytes(relabelled), throwsFormatException);
    });
  });

  group('the tap', () {
    test('a prompt is in the journal before sending returns', () {
      final body = bytes('{"model":"m"}');
      final reply = PromptTap(
        journal,
        'one',
        now: () => at,
      ).sending(claude, to, body, {'x-app': 'cli'});
      expect(entries(journal), 1);
      final kept = PromptRecord.fromBytes(journal.get(reply.prompt.object)!);
      expect(kept.body, body);
      expect(kept.source, claude);
      expect(kept.headers, {'x-app': 'cli'});
      expect(kept.sent, at);
    });

    test(
      'a prompt the journal cannot take is refused, and nothing is recorded',
      () {
        journal.close();
        expect(
          () => PromptTap(
            journal,
            'one',
          ).sending(claude, to, bytes('{}'), const {}),
          throwsStateError,
        );
        expect(entries(journal), 0);
      },
    );

    test('the reply is its pieces as they arrived, recorded once it ends, naming its prompt', () {
      final reply = PromptTap(
        journal,
        'one',
        now: () => at,
      ).sending(claude, to, bytes('{}'), const {});
      reply
        ..status(200, {
          'content-type': ['text/event-stream'],
        })
        ..chunk(bytes('event: a\n'))
        ..chunk(bytes('event: b\n'));
      expect(entries(journal), 1, reason: 'nothing more until it ends');
      final id = reply.ended(const ReplyComplete());
      expect(entries(journal), 2);
      final kept = ReplyRecord.fromBytes(journal.get(id)!);
      expect(kept.prompt, reply.prompt);
      expect(kept.status, 200);
      expect(kept.body, bytes('event: a\nevent: b\n'));
      expect(kept.end, const ReplyComplete());
    });

    test(
      'a reply the journal cannot take throws, so its answer is never used',
      () {
        final reply = PromptTap(journal, 'one').sending(
          claude,
          to,
          bytes('{}'),
          const {},
        )..chunk(bytes('the answer'));
        journal.close();
        expect(() => reply.ended(const ReplyComplete()), throwsStateError);
      },
    );
  });

  group('RecordedAirlock.prompting', () {
    RecordedAirlock<Object?> airlock() => RecordedAirlock<Object?>(
      journal,
      decide: (run, rules) => const Allow(by: DecidedBy.rules),
      narrows: (fewer, rules) => true,
    );

    test('shares the airlock\'s own journal', () {
      final tap = airlock().prompting('one', now: () => at);
      tap.sending(claude, to, bytes('{}'), const {});
      expect(entries(journal), 1);
    });
  });

  group('masking', () {
    test('the credential is masked by its own value, wherever it appears', () {
      expect(
        masked({
          'authorization': 'Bearer tok-123',
          'x-echo': 'sent tok-123 twice: tok-123',
          'x-app': 'cli',
        }),
        {
          'authorization': 'Bearer [masked]',
          'x-echo': 'sent [masked] twice: [masked]',
          'x-app': 'cli',
        },
      );
      expect(masked({'x-api-key': 'sk-ant-xyz', 'x-app': 'cli'}), {
        'x-api-key': '[masked]',
        'x-app': 'cli',
      });
    });

    test('headers with no credential pass through unchanged', () {
      expect(masked({'content-type': 'application/json'}), {
        'content-type': 'application/json',
      });
    });
  });
}
