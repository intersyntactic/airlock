/// An [Airlock] that decides and records runs under `is_airlock_api`,
/// sending every entry to `is_journal`'s one writer over a [RecordClient].
///
/// A journey path's decisions and outcomes are its own; what rules allow is
/// the app's to say, so [RecordedAirlock] takes that policy as a function
/// rather than guessing at a shape for `R`. What it owns is the record: one
/// entry per [Entry].
///
/// Sending a prompt to a model is not the airlock's job: the agent loop
/// writes each turn to the journal itself, and a model call's bytes are
/// recorded by whatever sends them, not by this package.
///
/// Nor does this package hold the journal itself any more: `is_journal`'s
/// one writer does, for every sender, and this is one of its senders.
///
/// Nor does it witness arrivals any more (Nick's ruling, 16 Nov): an
/// incoming event is recorded by whoever puts it on the record, not by the
/// airlock — a tool's effect is the airlock's whole concern now.
library;

// A caller can't build a RecordedAirlock without writing `decide`, which
// returns a Decision (Allow, Deny, DecidedBy) over a Reach — so these are
// part of RecordedAirlock's interface in practice, not just its own. Dart
// only lets a caller import its own direct dependencies, and is_airlock_api
// and is_effects are pinned here for reasons specific to this repo (see
// pubspec.yaml); re-exporting them keeps a caller from having to repeat
// that pin itself, with the two drifting apart if it ever changes here.
export 'package:is_airlock_api/is_airlock_api.dart';
export 'package:is_effects/is_effects.dart';

export 'src/record_client.dart';
export 'src/recorded_airlock.dart';
