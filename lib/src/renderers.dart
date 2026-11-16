/// `EntryReader`/[JournalEntryReader]: an [EntryReader] over
/// `is_journal_client`'s `JournalReader.get`, the one reviewed client for
/// is_journal's `get <entry>` — not a hand-rolled copy of its wire
/// protocol or its hash checks.
///
/// Built for the airlock to hand to a renderer it ran itself — is_airlock
/// no longer does that (Nick, 16 Nov: the airlock never talks to a
/// renderer; it decides, sends and records, and `Airlock.rendered` follows
/// the journal instead). This file is a handover staging area, not part of
/// is_airlock's own production surface any more: journal-0f and
/// teams-module-e2 are the ones who actually need a `get` client, for
/// reading a send's entries. Delete this file once they've taken it and
/// nothing here still depends on it.
library;

import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show EntryId;
import 'package:is_journal_client/is_journal_client.dart';

/// What reading one recorded entry found.
sealed class EntryRead {
  const EntryRead();
}

/// The entry's own bytes, exactly as the journal stores them (the header
/// included), already checked by `is_journal_client` against the entry's
/// 96 bytes: the record hashes to its id, and the record's own object
/// field names what the bytes actually hash to.
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
/// Passed in rather than built here, so a real implementation is a
/// one-line swap for whatever package actually needs this.
abstract interface class EntryReader {
  Future<EntryRead> read(EntryId id);
}

/// An [EntryReader] over `JournalReader.get`. `failed`, a malformed
/// request, or the socket closing early all come back as one of
/// `is_journal_client`'s own [ReadFailure] exceptions — this reader's own
/// bugs or the journal being unreachable, not something about one entry,
/// so they propagate rather than become an [EntryRead].
final class JournalEntryReader implements EntryReader {
  JournalEntryReader(this.socketPath);

  final String socketPath;

  @override
  Future<EntryRead> read(EntryId id) async {
    final hash = EntryHash.parse(id.toString())!;
    return switch (await JournalReader(socketPath).get(hash)) {
      GotEntry(:final entry) => EntryFound(entry.recorded),
      GotNone() => const EntryNotRecorded(),
      GotUnreadable(:final why) => EntryUnreadable(why),
      GotFailed(:final why) => throw ReadBroken(why),
    };
  }
}
