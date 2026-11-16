/// A client of `is_journal`'s one writer service: the only place this
/// package's record actually lives now. Sending an entry is one
/// connection: the request bytes out, the write side closed, one line of
/// answer back.
///
/// Every entry this package sends starts its own chain (`previous` is
/// always `-`, never a hash): witnessing an arrival and recording a
/// decision are each their own, standalone fact. Only the agent loop
/// appends to a journey path's own chain.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart';

/// The writer refused the entry outright: nothing was added, so sending
/// it again (once whatever [why] names is fixed) is safe.
final class RecordRefused implements Exception {
  const RecordRefused(this.why);

  final String why;

  @override
  String toString() => 'RecordRefused: $why';
}

/// The entry went in, but the writer isn't sure its object did — the
/// service's own shape for what `is_journal`'s `ObjectNotKept` meant
/// before there was a service in front of it. Sending the same fact
/// again would record it twice; this is not safe to retry as is.
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
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    socket.add(utf8.encode('$kind\n-\n'));
    socket.add(body);
    await socket.close();
    final line = (await utf8.decoder.bind(socket).join()).trim();
    final words = line.split(' ');
    return switch (words) {
      ['ok', final hex] =>
        EntryHash.parse(hex) ??
            (throw RecordFailed(
              'the writer answered a hash it cannot parse: $hex',
            )),
      ['refused', ...final why] => throw RecordRefused(why.join(' ')),
      ['failed', ...final why] => throw RecordFailed(why.join(' ')),
      _ => throw RecordFailed('not an answer the writer gives: $line'),
    };
  }
}
