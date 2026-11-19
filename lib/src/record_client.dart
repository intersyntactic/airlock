/// A client of `is_logbook`'s one writer service, over [LogbookWriter]
/// from `is_logbook_client` — the one reviewed client, not a hand-rolled
/// copy of its wire protocol.
///
/// Most entries this package sends start their own chain (`previous`
/// null): witnessing an arrival and recording a decision are each their
/// own, standalone fact. A result extends the decision it follows, which
/// [send]'s [previous] is for; only the agent loop appends to a journey
/// path's own chain.
library;

import 'dart:typed_data';

import 'package:is_logbook_client/is_logbook_client.dart';

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
  /// for this process's own user — with [body] as its payload, extending
  /// [previous]'s chain, or starting a new one when it is null. Returns
  /// the written entry's id.
  ///
  /// Throws [RecordRefused] or [RecordFailed] on anything but a plain
  /// success — never an id on a failure, since a caller that cannot tell
  /// the two apart could go on as though something had been recorded
  /// when nothing was, or send it again when it already had.
  /// [AlreadyRecorded] counts as success: these exact bytes, kind and
  /// previous are already in, by this call or an earlier one.
  Future<ObjectId> send(
    String kind,
    Uint8List body, {
    ObjectId? previous,
  }) async {
    final result = await LogbookWriter(
      socketPath,
    ).write(Kind.parse(kind)!, body, previous: previous);
    return switch (result) {
      Written(:final entry) || AlreadyRecorded(:final entry) => entry,
      NotTip() => throw RecordFailed(
        previous == null
            ? 'this package only ever starts its own chain here, so the '
                  'writer refusing for not being the tip is its own bug'
            : '$previous is no longer the tip',
      ),
      WriteRefused(:final why) => throw RecordRefused(why),
      WriteFailed(:final why) => throw RecordFailed(why),
      Unanswered(:final why) => throw RecordFailed(why),
    };
  }
}
