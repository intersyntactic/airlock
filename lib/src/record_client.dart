/// A client of `is_journal`'s one writer service, over [JournalWriter]
/// from `is_journal_client` — the one reviewed client, not a hand-rolled
/// copy of its wire protocol.
///
/// Every entry this package sends starts its own chain (`previous` is
/// always null): witnessing an arrival and recording a decision are each
/// their own, standalone fact. Only the agent loop appends to a journey
/// path's own chain.
library;

import 'dart:typed_data';

import 'package:is_journal_client/is_journal_client.dart';

/// The writer refused the entry outright: nothing was added, so sending
/// it again (once whatever [why] names is fixed) is safe.
final class RecordRefused implements Exception {
  const RecordRefused(this.why);

  final String why;

  @override
  String toString() => 'RecordRefused: $why';
}

/// The entry went in, but the writer isn't sure its object did, or there
/// was no telling what happened at all (the socket unreachable, closed
/// early, or silent past the deadline). Sending the same fact again would
/// risk recording it twice; this is not safe to retry as is.
final class RecordFailed implements Exception {
  const RecordFailed(this.why);

  final String why;

  @override
  String toString() => 'RecordFailed: $why';
}

final class RecordClient {
  const RecordClient(this.socketPath);

  /// The writer service's Unix socket.
  final String socketPath;

  /// Sends one entry of [kind] — a name the writer's sender table lists
  /// for this process's own user — with [body] as its payload, starting
  /// a new chain. Returns the written entry's hash.
  ///
  /// Throws [RecordRefused] or [RecordFailed] on anything but a plain
  /// success — never a hash on a failure, since a caller that cannot
  /// tell the two apart could go on as though something had been
  /// recorded when nothing was, or send it again when it already had.
  Future<EntryHash> send(String kind, Uint8List body) async {
    final result = await JournalWriter(socketPath).write(
      Kind.parse(kind)!,
      body,
    );
    return switch (result) {
      Written(:final entry) => entry,
      NotTip() => throw RecordFailed(
        'this package only ever starts its own chain, so the writer '
        'refusing for not being the tip is its own bug',
      ),
      WriteRefused(:final why) => throw RecordRefused(why),
      WriteFailed(:final why) => throw RecordFailed(why),
      Unanswered(:final why) => throw RecordFailed(why),
    };
  }
}
