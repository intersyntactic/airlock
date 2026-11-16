/// What `Airlock.rendered(decided)` needs (is_airlock_api 0.5.0, part 1,
/// https://github.com/intersyntactic/airlock_api/pull/10, not merged yet):
/// given a kept `Decided` entry, wait for the one entry that names it as
/// `previous` — a `Rendered` from the expected renderer, anything else, or
/// a timeout — and turn that into the `Outcome<String>` the driver is sent
/// with.
///
/// Built against is_journal's `subscribe` request (Nick retired "follow":
/// a reader subscribes, the record publishes), confirmed by journal-0f as
/// a wire rename only — `subscribe <kinds> from <entry>|start` in place of
/// `follow <kinds> <after>`, same behaviour, same reply bytes, `previous`
/// in place of `follows` as the name for what an entry points at. What
/// isn't settled — the wire shape of a `Rendered` entry, and how deeply
/// the airlock checks where it came from — is passed in as [parseRendered],
/// so this file doesn't guess at either.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_journal_client/is_journal_client.dart' as journal;

/// One entry as `subscribe` hands it back: enough to find the one that
/// names a given entry as [previous], without this file needing to know
/// any kind's own wire format.
final class SubscribedEntry {
  const SubscribedEntry({
    required this.hash,
    required this.kind,
    required this.previous,
    required this.body,
  });

  final String hash;
  final String kind;

  /// The hash of the entry this one names as what it comes after; null for
  /// an entry that starts its own chain.
  final String? previous;
  final Uint8List body;
}

/// Entries published after [from] (exclusive), of any kind, then live —
/// is_journal's `subscribe * from <entry>`. Passed in rather than built
/// here, so a real journal-backed subscriber is a one-line swap (see
/// [JournalEntrySubscriber]) for whatever still needs an [EntrySubscriber]
/// of its own.
///
/// An implementation must verify every entry before yielding it:
/// journal-client-7e found that `subscribe`'s own frames carry no 96
/// bytes, so nothing checks them the way `get` checks what it returns. A
/// caller of [waitForRendered] trusts [SubscribedEntry.body] completely —
/// a `Rendered`'s body becomes the bytes actually sent — so an
/// unverified entry here is exactly the kind of gap this whole system
/// otherwise never leaves open.
abstract interface class EntrySubscriber {
  Stream<SubscribedEntry> subscribe({required String from});
}

/// An [EntrySubscriber] over `JournalReader.subscribe`, re-verifying every
/// entry through `JournalReader.get` before yielding it — `subscribe`'s
/// own frames carry no 96 bytes, so nothing checks them otherwise. An
/// entry `get` can't confirm (not found, unreadable, or a mismatch) is
/// dropped rather than yielded unverified: [waitForRendered] keeps
/// waiting, which is safe, rather than trusting something that might be
/// fabricated.
final class JournalEntrySubscriber implements EntrySubscriber {
  JournalEntrySubscriber(this.socketPath);

  final String socketPath;

  @override
  Stream<SubscribedEntry> subscribe({required String from}) async* {
    final reader = journal.JournalReader(socketPath);
    final subscribed = reader.subscribe(
      from: journal.EntryHash.parse(from)!,
    );
    await for (final entry in subscribed) {
      if (entry is! journal.Entry) continue;
      // CaughtUp carries nothing waitForRendered needs: it only cares
      // about finding the one entry naming decidedHash as previous, not
      // where the backlog ended.
      final got = await reader.get(entry.hash);
      if (got is! journal.GotEntry) continue;
      final verified = got.entry;
      yield SubscribedEntry(
        hash: verified.hash.toString(),
        kind: verified.kind?.name ?? '-',
        previous: verified.previous?.toString(),
        body: verified.body,
      );
    }
  }
}

/// What [parseRendered] found in one subscribed entry: a renderer's
/// answer, or null when the entry isn't a `Rendered` at all (the wrong
/// kind in that slot — refused, but not forged, per RULINGS' walls: a
/// stranger can write an entry, but can't make it look like it came from
/// the renderer the `Decided` named without the writer's own sender check
/// agreeing).
final class RenderedAnswer {
  const RenderedAnswer({required this.renderedBy, this.body, this.refusal});

  /// Who actually wrote it, by whatever the writer's sender table can
  /// vouch for — a renderer's own claim is not enough on its own.
  final String renderedBy;
  final String? body;
  final String? refusal;
}

/// Waits for the entry that names [decidedHash] as its own previous — a
/// `Rendered` from [expectedRenderer], anything else, or nothing within
/// [timeout] — and answers with the `Outcome` is_airlock_api's own
/// `Airlock.rendered` needs to give back.
///
/// A late answer can never turn into anything else `Returned` would read
/// twice: a timeout here is reported to the caller, and this file does
/// not itself close the chain — that's `Returned`'s own job once "no
/// Rendered came" is known, which only needs writing once, by whoever is
/// actually about to record it.
Future<Outcome<String>> waitForRendered({
  required String decidedHash,
  required String expectedRenderer,
  required EntrySubscriber subscriber,
  required Duration timeout,
  required RenderedAnswer? Function(SubscribedEntry entry) parseRendered,
}) async {
  final entries = subscriber.subscribe(from: decidedHash).timeout(timeout);
  Outcome<String> outcome;
  try {
    outcome = Refused(
      'is_journal stopped publishing before anything arrived',
    );
    await for (final entry in entries) {
      if (entry.previous != decidedHash) continue;
      final rendered = parseRendered(entry);
      outcome = switch (rendered) {
        null => Refused(
          'expected a Rendered entry naming $decidedHash as previous, '
          'got ${entry.kind} from ${entry.hash}',
        ),
        RenderedAnswer(renderedBy: final by) when by != expectedRenderer =>
          Refused(
            'Rendered naming $decidedHash as previous came from $by, not '
            'the expected $expectedRenderer',
          ),
        RenderedAnswer(body: final body?) => Ran(body),
        RenderedAnswer(:final refusal) => Refused(
          refusal ?? 'the renderer refused',
        ),
      };
      break;
    }
  } on TimeoutException {
    outcome = Refused(
      'no entry named $decidedHash as previous within $timeout',
    );
  }
  return outcome;
}
