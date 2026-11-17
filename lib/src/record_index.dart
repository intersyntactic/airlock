/// Indexes the record's entries by content, so [DecidesAndRecordsActions
/// .recordedOn] can answer without a `get` — the record service's `get`
/// looks up only by `EntryHash`, the journal's own metadata-record hash,
/// never by `EntryId`, `is_shapes`' hash of an entry's own object bytes
/// (confirmed against logbook's `_read`/`_get`, airlock-api-04, 18 Nov:
/// there is no lookup by `EntryId` on the service side). Every entry this
/// package reads off the subscription already carries its own object
/// bytes, so the index is built as entries go by instead.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart' show EntryId, TrajectoryId;
import 'package:is_effects/is_effects.dart' show Outcome, Ran, Refused;
import 'package:is_journal_client/is_journal_client.dart' show EntryHash;

final class _Indexed {
  const _Indexed({required this.hash, required this.trajectory, required this.body});

  final EntryHash hash;
  final TrajectoryId? trajectory;
  final String body;
}

/// Which trajectory's chain each logbook entry is on, and what each one's
/// own content hashes to — [EntryId.of] its object bytes, header included,
/// never its [EntryHash].
final class RecordIndex {
  final _trajectoryOf = <EntryHash, TrajectoryId>{};

  /// Every entry by [EntryId.hex]: more than one, if two roots (`previous`
  /// `-`) happen to share a body — two entries with the same content on
  /// different chains have the same [EntryId] but different [EntryHash]es.
  final _byContent = <String, List<_Indexed>>{};

  /// [hash] roots [trajectory]'s chain: a `users-assigned-to-trajectory`
  /// entry. Call after [add]ing it, so a root is never mistaken for
  /// continuing some earlier chain by sharing a previous that happens to be
  /// null.
  void root(EntryHash hash, TrajectoryId trajectory) {
    _trajectoryOf[hash] = trajectory;
  }

  /// This trajectory's chain is on, if [hash] is on one at all.
  TrajectoryId? trajectoryOf(EntryHash hash) => _trajectoryOf[hash];

  /// Indexes [hash] (this entry's own hash), with [recorded] (its object
  /// bytes, header included) and [body] (the same, header stripped, what
  /// [recordedOn] actually gives back). [hash]'s trajectory is [previous]'s,
  /// if [previous] is on one — the same chain-walk [root] seeds.
  void add(
    EntryHash hash, {
    required EntryHash? previous,
    required Uint8List recorded,
    required Uint8List body,
  }) {
    final trajectory = previous == null ? null : _trajectoryOf[previous];
    if (trajectory != null) _trajectoryOf[hash] = trajectory;
    _byContent
        .putIfAbsent(EntryId.of(recorded).hex, () => [])
        .add(_Indexed(hash: hash, trajectory: trajectory, body: utf8.decode(body)));
  }

  /// [entry]'s content, when it is on [trajectory]'s own chain; [Refused]
  /// with why not. Never [get]s the record: everything needed already went
  /// by on the subscription (airlock-api-04, 18 Nov).
  Future<Outcome<String>> recordedOn(
    TrajectoryId trajectory,
    EntryId entry,
  ) async {
    final candidates = _byContent[entry.hex] ?? const [];
    for (final candidate in candidates) {
      if (candidate.trajectory == trajectory) return Ran(candidate.body);
    }
    return candidates.isEmpty
        ? Refused('${entry.hex} is not recorded')
        : Refused('${entry.hex} is on another chain');
  }
}
