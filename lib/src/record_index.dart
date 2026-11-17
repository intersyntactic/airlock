/// Indexes the record's entries by id, so [DecidesAndRecordsActions
/// .recordedOn] can answer without a `get`.
///
/// Under is_logbook 0.2.0 an entry's id is the [ObjectId] of its bytes —
/// the same sha256 [EntryId.of] computes over an entry's object text —
/// so chain-walking (by [Entry.previous]) and content lookup are now the
/// same id space: one entry, one id, found by [EntryId.hex] alongside
/// whatever is on it. (Under is_journal 0.7.0 these were two different
/// hashes over different bytes — a landmine this package once hit —
/// which is_logbook's rename of its wire ids to content hashes retires.)
/// Every entry this package reads off the subscription already carries
/// its own bytes, so the index is built as entries go by instead of a
/// second round trip to the service.
library;

import 'dart:convert';

import 'package:is_airlock_api/is_airlock_api.dart'
    show
        EntryId,
        TrajectoryId,
        readResultOfActionOrWhyRefused,
        resultOfActionOrWhyRefusedKind;
import 'package:is_effects/is_effects.dart' show Outcome, Ran, Refused;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;

final class _Indexed {
  const _Indexed({required this.trajectory, required this.kind, required this.body});

  final TrajectoryId? trajectory;
  final String kind;
  final String body;
}

/// Which trajectory's chain each logbook entry is on, and each one's kind
/// and content, by id.
final class RecordIndex {
  final _byId = <String, _Indexed>{};

  /// [id] roots [trajectory]'s chain: a `users-assigned-to-trajectory`
  /// entry. Call after [add]ing it, so a root is never mistaken for
  /// continuing some earlier chain by sharing a previous that happens to be
  /// null.
  void root(ObjectId id, TrajectoryId trajectory) {
    final entry = _byId[id.hex];
    if (entry != null) {
      _byId[id.hex] = _Indexed(
        trajectory: trajectory,
        kind: entry.kind,
        body: entry.body,
      );
    }
  }

  /// This trajectory's chain is on, if [id] is on one at all.
  TrajectoryId? trajectoryOf(ObjectId id) => _byId[id.hex]?.trajectory;

  /// Indexes [id] (this entry's own id), with [previous]'s trajectory, if
  /// it is on one — the same chain-walk [root] seeds — [kind] and [body]
  /// (the entry's bytes after its header, what [recordedOn] gives back).
  void add(
    ObjectId id, {
    required ObjectId? previous,
    required String kind,
    required String body,
  }) {
    final trajectory = previous == null ? null : _byId[previous.hex]?.trajectory;
    _byId[id.hex] = _Indexed(trajectory: trajectory, kind: kind, body: body);
  }

  /// Whether [indexed] belongs to [trajectory] because it is a
  /// [resultOfActionOrWhyRefusedKind] entry the airlock kept for one of
  /// its proposals: its own body names a `proposed` entry that is on
  /// [trajectory]'s chain.
  bool _resultBelongsTo(_Indexed indexed, TrajectoryId trajectory) {
    if (indexed.kind != resultOfActionOrWhyRefusedKind) return false;
    final read = readResultOfActionOrWhyRefused(_jsonOrNull(indexed.body));
    if (read == null) return false;
    return _byId[read.proposed.hex]?.trajectory == trajectory;
  }

  /// [entry]'s kind and content, when it belongs to [trajectory]: on its
  /// own chain, or a [resultOfActionOrWhyRefusedKind] entry kept for one of
  /// its proposals. [Refused] with why not. Never [get]s the record:
  /// everything needed already went by on the subscription (airlock-api-04,
  /// 18 Nov).
  Future<Outcome<({String kind, String body})>> recordedOn(
    TrajectoryId trajectory,
    EntryId entry,
  ) async {
    final indexed = _byId[entry.hex];
    if (indexed == null) return Refused('${entry.hex} is not recorded');
    if (indexed.trajectory == trajectory || _resultBelongsTo(indexed, trajectory)) {
      return Ran((kind: indexed.kind, body: indexed.body));
    }
    return Refused('${entry.hex} is on another chain');
  }
}

Object? _jsonOrNull(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
