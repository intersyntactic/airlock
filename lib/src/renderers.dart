/// `EntryReader`/[JournalEntryReader]: a correct, tested client for
/// is_journal's `get <entry>` (0.6.0, its wire shape settled with
/// journal-0f, though not published yet).
///
/// Built for the airlock to hand to a renderer it ran itself — is_airlock
/// no longer does that (Nick, 16 Nov: the airlock never talks to a
/// renderer; it decides, sends and records, and `Airlock.rendered` follows
/// the journal instead). This file is a handover staging area, not part of
/// is_airlock's own production surface any more: journal-0f is taking the
/// `get` client into is_journal 0.6.0 itself, teams-module-e2 has a
/// stand-in copy on their own branch meanwhile. Delete this file once
/// 0.6.0 is published and nothing here still depends on it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';

/// What reading one recorded entry found.
sealed class EntryRead {
  const EntryRead();
}

/// The entry's own bytes, exactly as the journal stores them.
final class EntryFound extends EntryRead {
  const EntryFound(this.bytes);
  final Uint8List bytes;
}

/// `none <hash>`: the entry was never recorded.
final class EntryNotRecorded extends EntryRead {
  const EntryNotRecorded();
}

/// `unreadable <hash> missing|corrupt`: the entry was recorded, but its
/// bytes can't be read right now. Kept apart from [EntryNotRecorded] so a
/// refusal's reason says which — one means it never happened, the other
/// that it did and the record is hurt.
final class EntryUnreadable extends EntryRead {
  const EntryUnreadable(this.why);
  final String why;
}

/// Reads one recorded entry by its id, over is_journal's read socket.
/// Passed in rather than built here, so a real implementation of `get
/// entry` is a one-line swap once is_journal 0.6.0 exists.
abstract interface class EntryReader {
  Future<EntryRead> read(EntryId id);
}

/// An [EntryReader] over is_journal's read socket (`get <entry>`, 0.6.0 —
/// its wire shape is settled, confirmed with journal-0f, though the
/// version itself isn't published yet).
///
/// `get`'s answer carries the entry's own 96-byte record (previous│code│
/// object, hex) and, when found, the content it names. This class does
/// both checks journal-0f's protocol asks of a caller before trusting
/// either: the record hashes to the id it was asked for, and the record's
/// own `object` field names what the content actually hashes to. Neither
/// is optional — skipping either lets a compromised or buggy journal hand
/// back content for the wrong entry, or an entry that was never really
/// kept.
///
/// `none`/`unreadable` become [EntryNotRecorded]/[EntryUnreadable] — about
/// this one entry, worth a specific refusal reason. `failed`, a malformed
/// request, or the socket closing early are this reader's own bugs or the
/// journal being unreachable, not something about one entry, so they throw
/// a [StateError] instead.
final class JournalEntryReader implements EntryReader {
  JournalEntryReader(this.socketPath);

  final String socketPath;

  /// Journal-0f: the service closes the connection once it has sent its
  /// one answer, so there is never a second request to confuse this read
  /// with another's — reading to EOF and parsing locally needs no state
  /// carried from one call to the next.
  @override
  Future<EntryRead> read(EntryId id) async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final Uint8List all;
    try {
      socket.add(utf8.encode('get $id\n'));
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in socket) {
        bytes.add(chunk);
      }
      all = bytes.takeBytes();
    } finally {
      socket.destroy();
    }

    final newline = all.indexOf(0x0a);
    if (newline < 0) {
      throw StateError('get $id: journal closed before answering');
    }
    final line = utf8.decode(Uint8List.sublistView(all, 0, newline));
    final body = Uint8List.sublistView(all, newline + 1);
    final words = line.split(' ');
    return switch (words) {
      ['entry', final hash, _, _, final lengthText, final entryHex]
          when hash == id.toString() =>
        _found(id, int.parse(lengthText), entryHex, body),
      ['none', _] => const EntryNotRecorded(),
      ['unreadable', _, final why] => EntryUnreadable(why),
      ['failed', ...final message] =>
        throw StateError('get $id failed: ${message.join(' ')}'),
      ['refused', ...final why] =>
        throw StateError('get $id refused: ${why.join(' ')}'),
      _ => throw StateError('get $id: not an answer the journal gives'),
    };
  }

  EntryRead _found(EntryId id, int length, String entryHex, Uint8List body) {
    final record = _unhex(entryHex);
    if (record.length != 96 || EntryId.of(record) != id) {
      return EntryUnreadable('its own record does not hash to $id');
    }
    if (body.length != length) {
      throw StateError(
        'get $id: journal closed before sending all $length bytes',
      );
    }
    final object = ObjectId.fromDigest(Uint8List.sublistView(record, 64, 96));
    if (object == null || ObjectId.of(body) != object) {
      return EntryUnreadable('its content does not match its own record');
    }
    return EntryFound(body);
  }
}

Uint8List _unhex(String hex) => Uint8List.fromList([
  for (var i = 0; i + 1 < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);
