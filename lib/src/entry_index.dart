/// Indexes the logbook's entries by id, so [DecidesAndRecordsActions
/// .recordedOn] can answer without a `get`.
///
/// Under is_logbook 0.2.0 an entry's id is the [ObjectId] of its bytes —
/// the same sha256 [EntryId.of] computes over an entry's object text —
/// so chain identity and content identity are now the same id space: one
/// entry, one id, found by [EntryId.hex] alongside whatever is on it.
/// (Under is_journal 0.7.0 these were two different hashes over different
/// bytes — a landmine this package once hit — which is_logbook's rename of
/// its wire ids to content hashes retires.) Every entry this package reads
/// off the subscription already carries its own bytes and its own
/// trajectory (is_logbook 0.5.0, is_logbook_client 0.4.0 — the service
/// stamps each entry with the trajectory that owns its chain, so this
/// package no longer walks [Entry.previous] to work that out itself), so
/// the index is built as entries go by instead of a second round trip to
/// the service.
library;

import 'package:is_airlock_api/is_airlock_api.dart'
    show
        EntryId,
        TrajectoryId,
        readOutcomeOfProposedAction,
        outcomeOfProposedActionKind;
import 'package:is_effects/is_effects.dart' show NothingRan, Outcome, Ran;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;

final class _Indexed {
  const _Indexed({
    required this.trajectory,
    required this.kind,
    required this.body,
  });

  final TrajectoryId? trajectory;
  final String kind;
  final String body;
}

/// Which trajectory's chain each logbook entry is on, and each one's kind
/// and content, by id.
final class EntryIndex {
  final _byId = <String, _Indexed>{};

  /// This trajectory's chain is on, if [id] is on one at all.
  TrajectoryId? trajectoryOf(ObjectId id) => _byId[id.hex]?.trajectory;

  /// Indexes [id] (this entry's own id) with [trajectory] (the service's own
  /// stamp — null when no trajectory owns the entry's chain), [kind] and
  /// [body] (the entry's bytes after its header, what [entryOn] gives back).
  void add(
    ObjectId id, {
    required TrajectoryId? trajectory,
    required String kind,
    required String body,
  }) {
    _byId[id.hex] = _Indexed(trajectory: trajectory, kind: kind, body: body);
  }

  /// [id]'s own kind and body, exactly as [add] indexed them — no trajectory
  /// check, unlike [entryOn]. Only for a caller that has already established
  /// [id] belongs where it's using it some other way (an admission this
  /// package decoded and checked itself, never an id a loop handed it):
  /// [entryOn] is the trajectory-checked accessor for anything a loop names.
  ({String kind, String body})? raw(EntryId id) {
    final indexed = _byId[id.hex];
    return indexed == null ? null : (kind: indexed.kind, body: indexed.body);
  }

  /// Whether [indexed] belongs to [trajectory] because it is a
  /// [outcomeOfProposedActionKind] entry the airlock kept for one of
  /// its proposals: its own body names a `proposed` entry that is on
  /// [trajectory]'s chain.
  bool _resultBelongsTo(_Indexed indexed, TrajectoryId trajectory) {
    if (indexed.kind != outcomeOfProposedActionKind) return false;
    final read = readOutcomeOfProposedAction(indexed.body);
    if (read == null) return false;
    return _byId[read.proposed.hex]?.trajectory == trajectory;
  }

  /// [entry]'s kind and content, when it belongs to [trajectory]: on its
  /// own chain, or a [outcomeOfProposedActionKind] entry kept for one of
  /// its proposals. [NothingRan] with why not. Never gets the logbook:
  /// everything needed already went by on the subscription (airlock-api-04,
  /// 18 Nov).
  Future<Outcome<({String kind, String body})>> entryOn(
    TrajectoryId trajectory,
    EntryId entry,
  ) async {
    final indexed = _byId[entry.hex];
    if (indexed == null) return NothingRan('${entry.hex} is not in the logbook');
    if (indexed.trajectory == trajectory ||
        _resultBelongsTo(indexed, trajectory)) {
      return Ran((kind: indexed.kind, body: indexed.body));
    }
    return NothingRan('${entry.hex} is on another chain');
  }
}
