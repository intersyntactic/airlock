/// What went up to a model at each prompt, and what came back, each added
/// to this airlock's journal as one entry.
///
/// An entry is one line of JSON saying what crossed (where it went, when,
/// the headers, how a reply ended), then the bytes that crossed, as they
/// crossed and encoded again by nothing.
///
/// A prompt is in the journal before it goes, and if it can't be, it
/// doesn't go: [PromptTap.sending] is the only way to a [ReplyTap]. A reply
/// the journal can't take throws rather than being logged and passed on,
/// because the record is the reply's provenance, and text with none is
/// unusable.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart';

import 'arrival_source.dart';

/// A prompt's id: the journal object that says what went up.
final class PromptId {
  const PromptId._(this.object);

  final ObjectId object;

  @override
  bool operator ==(Object other) => other is PromptId && other.object == object;

  @override
  int get hashCode => object.hashCode;
}

const _prompt = 'model prompt';
const _reply = 'model reply';
const _lineBreak = 0x0a;

/// [notes] as one line of JSON, then [bytes]. `jsonEncode` escapes every
/// line break inside a string, so the first line break ends the notes.
Uint8List _crossing(String kind, Map<String, Object?> notes, List<int> bytes) =>
    (BytesBuilder(copy: false)
          ..add(utf8.encode(jsonEncode({'kind': kind, ...notes})))
          ..addByte(_lineBreak)
          ..add(bytes))
        .takeBytes();

/// The notes and the bytes of an object [_crossing] wrote as [kind]. Throws
/// a [FormatException] for anything else.
(Map<String, Object?>, Uint8List) _split(String kind, Uint8List object) {
  final end = object.indexOf(_lineBreak);
  if (end < 0) throw const FormatException('a prompt record with no notes');
  final Object? notes = jsonDecode(
    utf8.decode(Uint8List.sublistView(object, 0, end)),
  );
  if (notes case Map<String, Object?> m when m['kind'] == kind) {
    return (m, Uint8List.sublistView(object, end + 1));
  }
  throw FormatException('not a $kind');
}

Map<String, String> _headers(Object? json) => switch (json) {
  Map<String, Object?> m => {
    for (final MapEntry(:key, :value) in m.entries)
      key: value is String
          ? value
          : throw FormatException('a header that is not a string', key),
  },
  _ => throw const FormatException('headers that are not an object'),
};

Map<String, List<String>> _replyHeaders(Object? json) => switch (json) {
  Map<String, Object?> m => {
    for (final MapEntry(:key, :value) in m.entries)
      key: switch (value) {
        List<Object?> values => [
          for (final v in values)
            v is String
                ? v
                : throw FormatException('a header that is not a string', key),
        ],
        _ => throw FormatException('a reply header that is not a list', key),
      },
  },
  _ => throw const FormatException('headers that are not an object'),
};

/// What went up at one prompt.
final class PromptRecord {
  const PromptRecord({
    required this.pass,
    required this.source,
    required this.to,
    required this.sent,
    required this.headers,
    required this.body,
  });

  /// The pass that sent it: the name intersyntactic's record gives the run
  /// a prompt belongs to.
  final String pass;

  /// The model it went to, such as `claude` or `ollama`. Not [pass]'s job:
  /// [pass] says which run sent it, this says which model answered.
  final ArrivalSource source;

  /// Where it went.
  final Uri to;

  /// When it was written, just before it went.
  final DateTime sent;

  /// Its headers, with the credential masked ([masked]).
  final Map<String, String> headers;

  /// Its body, exactly as sent.
  final Uint8List body;

  Uint8List toBytes() => _crossing(_prompt, {
    'journey': pass,
    'source': source.value,
    'to': '$to',
    'sent': sent.toUtc().toIso8601String(),
    'headers': headers,
  }, body);

  /// Throws a [FormatException] when [object] is not one [toBytes] wrote.
  static PromptRecord fromBytes(Uint8List object) {
    final (notes, body) = _split(_prompt, object);
    if (notes case {
      'journey': String pass,
      'source': String source,
      'to': String to,
      'sent': String sent,
      'headers': final headers,
    }) {
      return PromptRecord(
        pass: pass,
        source:
            ArrivalSource.parse(source) ??
            (throw FormatException('not a source', source)),
        to: Uri.parse(to),
        sent: DateTime.parse(sent),
        headers: _headers(headers),
        body: body,
      );
    }
    throw FormatException('a $_prompt missing its notes', notes);
  }
}

/// How a reply's body ended.
sealed class ReplyEnd {
  const ReplyEnd();

  /// How the record says it.
  String get wire;
}

final class ReplyComplete extends ReplyEnd {
  const ReplyComplete();

  @override
  String get wire => 'complete';
}

/// Stopped on our side before the body was over.
final class ReplyCancelled extends ReplyEnd {
  const ReplyCancelled();

  @override
  String get wire => 'cancelled';
}

final class ReplyFailed extends ReplyEnd {
  const ReplyFailed(this.why);

  final String why;

  @override
  String get wire => 'failed';

  @override
  bool operator ==(Object other) => other is ReplyFailed && other.why == why;

  @override
  int get hashCode => why.hashCode;
}

/// What came back at one prompt.
final class ReplyRecord {
  const ReplyRecord({
    required this.prompt,
    required this.headers,
    required this.end,
    required this.ended,
    required this.body,
    this.status,
  });

  /// The prompt this replies to.
  final PromptId prompt;

  /// Null when the prompt failed before a status arrived.
  final int? status;
  final Map<String, List<String>> headers;
  final ReplyEnd end;

  /// When the body was over.
  final DateTime ended;

  /// The body's bytes as they arrived, before anything read them.
  final Uint8List body;

  Uint8List toBytes() => _crossing(_reply, {
    'prompt': prompt.object.hex,
    if (status != null) 'status': status,
    'headers': headers,
    'end': end.wire,
    if (end case ReplyFailed(:final why)) 'error': why,
    'ended': ended.toUtc().toIso8601String(),
  }, body);

  /// Throws a [FormatException] when [object] is not one [toBytes] wrote.
  static ReplyRecord fromBytes(Uint8List object) {
    final (notes, body) = _split(_reply, object);
    if (notes case {
      'prompt': String prompt,
      'headers': final headers,
      'end': String end,
      'ended': String ended,
    }) {
      return ReplyRecord(
        prompt: PromptId._(
          ObjectId.parse(prompt) ??
              (throw FormatException('not an object id', prompt)),
        ),
        status: switch (notes['status']) {
          int status => status,
          null => null,
          final other => throw FormatException(
            'a status that is not a number',
            other,
          ),
        },
        headers: _replyHeaders(headers),
        end: switch ((end, notes['error'])) {
          ('complete', null) => const ReplyComplete(),
          ('cancelled', null) => const ReplyCancelled(),
          ('failed', String why) => ReplyFailed(why),
          _ => throw FormatException('not how a reply ends', end),
        },
        ended: DateTime.parse(ended),
        body: body,
      );
    }
    throw FormatException('a $_reply missing its notes', notes);
  }
}

/// Records each prompt made under [pass] in a journal: [RecordedAirlock]'s
/// own, from [RecordedAirlock.prompting].
final class PromptTap {
  PromptTap(this._journal, this.pass, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  final Journal _journal;

  /// The name intersyntactic's record gives the run making this pass's
  /// prompts.
  final String pass;

  /// When each prompt goes up and each reply ends.
  final DateTime Function() now;

  /// Adds the prompt about to go to [to] (its [body] exactly as it will be
  /// sent, its [headers] already [masked]) at [source], and returns what
  /// records its reply. Throws when the journal can't take it, and then
  /// the prompt must not go.
  ReplyTap sending(
    ArrivalSource source,
    Uri to,
    Uint8List body,
    Map<String, String> headers,
  ) {
    final prompt = PromptRecord(
      pass: pass,
      source: source,
      to: to,
      sent: now(),
      headers: headers,
      body: body,
    );
    return ReplyTap._(this, PromptId._(_journal.add(prompt.toBytes())));
  }
}

/// Gathers one reply's bytes as they arrive and records them when it ends.
final class ReplyTap {
  ReplyTap._(this._tap, this.prompt);

  final PromptTap _tap;

  /// The prompt this replies to.
  final PromptId prompt;

  final _body = BytesBuilder(copy: true);
  int? _status;
  Map<String, List<String>> _headers = const {};

  void status(int code, Map<String, List<String>> headers) {
    _status = code;
    _headers = headers;
  }

  void chunk(List<int> bytes) => _body.add(bytes);

  /// Adds the reply and returns its id. Throws when the journal can't take
  /// it, and then the reply must not be used.
  ObjectId ended(ReplyEnd how) => _tap._journal.add(
    ReplyRecord(
      prompt: prompt,
      status: _status,
      headers: _headers,
      end: how,
      ended: _tap.now(),
      body: _body.takeBytes(),
    ).toBytes(),
  );
}

/// [headers] with the credential they carry replaced by `[masked]` wherever
/// it appears: the `authorization` header's value after its scheme, and
/// `x-api-key`'s. The prompt's own headers say what the credential is, so
/// whatever sends a prompt on can mask it without holding it.
Map<String, String> masked(Map<String, String> headers) {
  final secrets = [
    if (headers['authorization'] case final auth?)
      auth.substring(auth.indexOf(' ') + 1),
    ?headers['x-api-key'],
  ].where((s) => s.isNotEmpty).toList();
  return headers.map(
    (name, value) => MapEntry(
      name,
      secrets.fold(value, (v, s) => v.replaceAll(s, '[masked]')),
    ),
  );
}
