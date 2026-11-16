/// What `Airlock.rendered(decided)` needs (is_airlock_api 0.5.0, part 1,
/// https://github.com/intersyntactic/airlock_api/pull/10, not merged yet):
/// given a kept `Decided` entry, wait for the one entry that follows it —
/// a `Rendered` from the expected renderer, anything else, or a timeout —
/// and turn that into the `Outcome<String>` the driver is sent with.
///
/// Built against is_journal's `follow` protocol, which is already settled
/// and live on 0.5.0 (confirmed with journal-0f: the per-post chain design
/// needs no journal change). What isn't settled — the wire shape of a
/// `Rendered` entry, and how deeply the airlock checks where it came from
/// — is passed in as [parseRendered], so this file doesn't guess at either.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';

/// One entry as `follow` hands it back: enough to find the one that
/// follows a given hash, without this file needing to know any kind's own
/// wire format.
final class FollowedEntry {
  const FollowedEntry({
    required this.hash,
    required this.kind,
    required this.follows,
    required this.body,
  });

  final String hash;
  final String kind;

  /// The hash of the entry this one follows; null for a chain's own start.
  final String? follows;
  final Uint8List body;
}

/// Entries recorded after [after] (exclusive), of any kind, then live —
/// is_journal's `follow * <after>`. Passed in rather than built here, same
/// reason as everywhere else this session: its wire shape is settled, but
/// there's nothing published yet to connect to for real.
abstract interface class EntryFollower {
  Stream<FollowedEntry> follow({required String after});
}

/// What [parseRendered] found in one followed entry: a renderer's answer,
/// or null when the entry isn't a `Rendered` at all (the wrong kind in
/// that slot — refused, but not forged, per RULINGS' walls: a stranger can
/// write an entry, but can't make it look like it came from the renderer
/// the `Decided` named without the writer's own sender check agreeing).
final class RenderedAnswer {
  const RenderedAnswer({required this.renderedBy, this.body, this.refusal});

  /// Who actually wrote it, by whatever the writer's sender table can
  /// vouch for — a renderer's own claim is not enough on its own.
  final String renderedBy;
  final String? body;
  final String? refusal;
}

/// Waits for the entry that follows [decidedHash] — a `Rendered` from
/// [expectedRenderer], anything else, or nothing within [timeout] — and
/// answers with the `Outcome` is_airlock_api's own `Airlock.rendered`
/// needs to give back.
///
/// A late answer can never turn into anything else `Returned` would read
/// twice: a timeout here is reported to the caller, and this file does
/// not itself close the chain — that's `Returned`'s own job once "no
/// Rendered came" is known, which only needs writing once, by whoever is
/// actually about to record it.
Future<Outcome<String>> waitForRendered({
  required String decidedHash,
  required String expectedRenderer,
  required EntryFollower follower,
  required Duration timeout,
  required RenderedAnswer? Function(FollowedEntry entry) parseRendered,
}) async {
  final entries = follower.follow(after: decidedHash).timeout(timeout);
  Outcome<String> outcome;
  try {
    outcome = Refused(
      'is_journal stopped following before anything arrived',
    );
    await for (final entry in entries) {
      if (entry.follows != decidedHash) continue;
      final rendered = parseRendered(entry);
      outcome = switch (rendered) {
        null => Refused(
          'expected a Rendered entry following $decidedHash, '
          'got ${entry.kind} from ${entry.hash}',
        ),
        RenderedAnswer(renderedBy: final by) when by != expectedRenderer =>
          Refused(
            'Rendered following $decidedHash came from $by, not the '
            'expected $expectedRenderer',
          ),
        RenderedAnswer(body: final body?) => Ran(body),
        RenderedAnswer(:final refusal) => Refused(
          refusal ?? 'the renderer refused',
        ),
      };
      break;
    }
  } on TimeoutException {
    outcome = Refused('no entry followed $decidedHash within $timeout');
  }
  return outcome;
}
