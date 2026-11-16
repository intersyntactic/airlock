/// This package's half of [Renderers]: reading and verifying every entry a
/// post draws from, before a renderer draws its words.
///
/// What actually runs a renderer — the executable, with no network and no
/// secrets, checking what it reports it was built from — is not yet
/// specified (airlock-api-04, infra-5e and Nick are routing it). So is
/// finding one by name: where the registry lives, and whether its
/// `executable` points at a journal object (is_journal 0.7.0) or, for now,
/// a local file. [RecordedRenderers] takes both as functions, same as
/// [RecordedAirlock] takes `decide`, so neither gap blocks what's already
/// settled: reading one recorded entry, which is_journal's `get <entry>`
/// now has a wire shape for (0.6.0, not built yet, but agreed).
library;

import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';

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

/// A [Renderers] built from the pieces available today: a real,
/// tested [EntryReader] for the part is_journal's wire shape now settles,
/// and `find`/`run` as functions for the parts that aren't yet.
final class RecordedRenderers implements Renderers {
  RecordedRenderers(this._reader, this._find, this._run);

  final EntryReader _reader;
  final Future<Renderer?> Function(RendererName name) _find;
  final Future<Outcome<String>> Function(
    Renderer renderer,
    List<Uint8List> entries,
  )
  _run;

  @override
  Future<Renderer?> find(RendererName name) => _find(name);

  /// Reads each of [entries] and checks it hashes to its own id — the one
  /// check this class can make today, since `EntryId.of` is defined on the
  /// entry's bytes regardless of where they came from. A missing or
  /// unreadable entry refuses the post, naming which; so does one whose
  /// bytes don't hash to the id it was asked for, which a correct
  /// [EntryReader] should never hand back, but this class doesn't trust
  /// that blindly.
  @override
  Future<Outcome<String>> render(
    Renderer renderer,
    List<EntryId> entries,
  ) async {
    final bodies = <Uint8List>[];
    for (final id in entries) {
      switch (await _reader.read(id)) {
        case EntryFound(:final bytes):
          if (EntryId.of(bytes) != id) {
            return Refused('entry $id does not hash to its own id');
          }
          bodies.add(bytes);
        case EntryNotRecorded():
          return Refused('entry $id was never recorded');
        case EntryUnreadable(:final why):
          return Refused('entry $id is unreadable: $why');
      }
    }
    return _run(renderer, bodies);
  }
}
