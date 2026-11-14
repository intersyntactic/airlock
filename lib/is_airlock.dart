/// An [Airlock] that decides and records runs under `is_airlock_api`, kept
/// in an add-only [Journal] from `is_journal`.
///
/// A journey path's decisions and outcomes are its own; what rules allow is
/// the app's to say, so [RecordedAirlock] takes that policy as two functions
/// rather than guessing at a shape for `R`. What it owns is the record: one
/// line per [Entry], and, for what reaches the airlock before any journey
/// path exists to record it, [Witness.witness].
///
/// Sending a prompt to a model is not the airlock's job: the agent loop
/// writes each turn to the journal itself, and a model call's bytes are
/// recorded by whatever sends them, not by this package.
library;

// A caller can't build a RecordedAirlock without writing `decide`, which
// returns a Decision (Allow, Deny, DecidedBy) over a Run — so these are
// part of RecordedAirlock's interface in practice, not just its own. Dart
// only lets a caller import its own direct dependencies, and is_airlock_api
// and is_effects are pinned here for reasons specific to this repo (see
// pubspec.yaml); re-exporting them keeps a caller from having to repeat
// that pin itself, with the two drifting apart if it ever changes here.
export 'package:is_airlock_api/is_airlock_api.dart';
export 'package:is_effects/is_effects.dart';

export 'src/arrival_source.dart';
export 'src/recorded_airlock.dart';
