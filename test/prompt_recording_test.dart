import 'dart:async';
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
final pass = JourneyPathId.parse('one')!;

Uint8List bytes(String s) => utf8.encode(s);

PromptId promptId(Uint8List bytes) => PromptId.of(ObjectId.of(bytes));

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
        pass: pass,
        source: claude,
        to: to,
        sent: at,
        headers: MaskedHeaders.of({
          'authorization': 'Bearer secret-token',
          'content-type': 'application/json',
        }),
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
      expect(read.pass, pass);
      expect(read.source, claude);
      expect(read.to, to);
      expect(read.sent, at);
      expect(read.headers.value, {
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
        final prompt = promptId(bytes('{}'));
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
        final written = ReplyRecord(
          prompt: promptId(bytes('{}')),
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
        pass: pass,
        source: claude,
        to: to,
        sent: at,
        headers: MaskedHeaders.of(const {}),
        body: bytes('{}'),
      ).toBytes();
      expect(() => ReplyRecord.fromBytes(prompt), throwsFormatException);
      final reply = ReplyRecord(
        prompt: promptId(bytes('{}')),
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
        pass: pass,
        source: claude,
        to: to,
        sent: at,
        headers: MaskedHeaders.of(const {}),
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

  group('Witness.prompt', () {
    late HttpServer server;
    late Uri serverTo;

    // A pipeline sending its own prompts needs no rules and decides no
    // runs, so it builds a bare Witness — never a RecordedAirlock, which
    // would mean inventing policy it doesn't have.
    Witness witness() => Witness(journal);

    tearDown(() async {
      await server.close(force: true);
    });

    test('the prompt is in the journal before it is sent, masked, and the reply, as it arrived, names it', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverTo = Uri.parse('http://127.0.0.1:${server.port}/v1/messages');
      final requestBody = Completer<String>();
      unawaited(() async {
        final req = await server.first;
        requestBody.complete(await utf8.decodeStream(req));
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'text/event-stream');
        req.response.write('event: a\n');
        await req.response.flush();
        req.response.write('event: b\n');
        await req.response.close();
      }());

      final body = bytes('{"model":"m"}');
      final (replyId, reply) = await witness().prompt(
        pass,
        claude,
        serverTo,
        body,
        {
          'authorization': 'Bearer secret-token',
          'content-type': 'application/json',
        },
        now: () => at,
      );

      expect(await requestBody.future, '{"model":"m"}');
      expect(reply.status, 200);
      expect(reply.headers['content-type'], ['text/event-stream']);
      expect(reply.body, bytes('event: a\nevent: b\n'));
      expect(reply.end, const ReplyComplete());
      expect(reply.ended, at);

      // Two entries: the prompt, then the reply, and the reply's own id
      // reads back the same bytes the call returned.
      expect(entries(journal), 2);
      expect(ReplyRecord.fromBytes(journal.get(replyId)!).body, reply.body);
      final kept = PromptRecord.fromBytes(journal.get(reply.prompt.object)!);
      expect(kept.headers.value['authorization'], 'Bearer [masked]');
      expect(kept.body, body);
      expect(kept.source, claude);
    });

    test(
      'the real credential never reaches the journal, only [masked]',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        serverTo = Uri.parse('http://127.0.0.1:${server.port}/v1/messages');
        const secret = 'sk-ant-this-must-never-be-written-to-disk';
        unawaited(() async {
          final req = await server.first;
          // The real secret did arrive on the wire, exactly where it
          // should — only the journal must never hold it.
          expect(req.headers.value('authorization'), 'Bearer $secret');
          await req.drain<void>();
          await req.response.close();
        }());

        await witness().prompt(pass, claude, serverTo, bytes('{}'), {
          'authorization': 'Bearer $secret',
        }, now: () => at);

        // Every byte this journal has ever kept, not just the one field a
        // decoder happens to read back: the credential must appear nowhere
        // in objects/, under any encoding this process might have chosen.
        final objectsDir = Directory('${tmp.path}/journal/objects');
        for (final file
            in objectsDir.listSync(recursive: true).whereType<File>()) {
          expect(
            utf8.decode(file.readAsBytesSync(), allowMalformed: true),
            isNot(contains(secret)),
            reason: 'found the real credential in ${file.path}',
          );
        }
      },
    );

    test('no Accept-Encoding is added, so the body recorded matches the body sent, compressed or not', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverTo = Uri.parse('http://127.0.0.1:${server.port}/v1/messages');
      final sawAcceptEncoding = Completer<String?>();
      final gzipped = gzip.encode(utf8.encode('plain text reply'));
      unawaited(() async {
        final req = await server.first;
        await req.drain<void>();
        sawAcceptEncoding.complete(
          req.headers.value(HttpHeaders.acceptEncodingHeader),
        );
        req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        req.response.add(gzipped);
        await req.response.close();
      }());

      final (_, reply) = await witness().prompt(
        pass,
        claude,
        serverTo,
        bytes('{}'),
        const {'accept-encoding': 'gzip'},
        now: () => at,
      );

      // The caller asked for gzip itself; nothing was added on its behalf.
      expect(await sawAcceptEncoding.future, 'gzip');
      // Recorded and returned as the compressed bytes the server actually
      // sent, matching the content-encoding header recorded alongside
      // them — not silently decompressed by the client underneath.
      expect(reply.body, gzipped);
      expect(reply.headers[HttpHeaders.contentEncodingHeader], ['gzip']);
    });

    test(
      'a prompt the journal cannot take is refused, and nothing is sent',
      () async {
        journal.close();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

        await expectLater(
          witness().prompt(
            pass,
            claude,
            Uri.parse('http://127.0.0.1:${server.port}/'),
            bytes('{}'),
            const {},
          ),
          throwsStateError,
        );
        expect(server.connectionsInfo().total, 0);
      },
    );

    test('a reply refused by nothing listening is recorded as failed, naming its prompt', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final unreachable = Uri.parse('http://127.0.0.1:${server.port}/');
      await server.close(force: true);

      final (_, reply) = await witness().prompt(
        pass,
        claude,
        unreachable,
        bytes('{}'),
        const {},
        now: () => at,
      );

      expect(reply.status, isNull);
      expect(reply.end, isA<ReplyFailed>());
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
  });

  group('RecordedAirlock', () {
    test('is also a Witness: prompt works the same way', () async {
      final airlock = RecordedAirlock<Object?, Object?>(
        journal,
        decide: (run, rules) => const Allow(by: DecidedBy.rules),
        narrows: (fewer, rules) => true,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.first.then((req) async {
          await req.drain<void>();
          await req.response.close();
        }),
      );

      final (_, reply) = await airlock.prompt(
        pass,
        claude,
        Uri.parse('http://127.0.0.1:${server.port}/'),
        bytes('{}'),
        const {},
      );

      expect(reply.end, const ReplyComplete());
      await server.close(force: true);
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
