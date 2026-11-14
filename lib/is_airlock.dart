/// An [Airlock] that decides and records runs under `is_airlock_api`, kept
/// in an add-only [Journal] from `is_journal`.
///
/// A journey path's decisions and outcomes are its own; what rules allow is
/// the app's to say, so [JournalAirlock] takes that policy as two functions
/// rather than guessing at a shape for `R`. What it owns is the record: one
/// line per [Entry], and, for what reaches the airlock before any journey
/// path exists to record it, [JournalAirlock.witness].
library;

export 'src/arrival_source.dart';
export 'src/journal_airlock.dart';
