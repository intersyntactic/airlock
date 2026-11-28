/// An [Airlock] that decides and writes to the logbook under
/// `is_airlock_api`, sending every entry to `is_logbook`'s one writer over
/// a [LogbookClient].
///
/// A trajectory's decisions and outcomes are its own; what rules allow is
/// the app's to say, so [Airlock] takes that policy as a function
/// rather than guessing at a shape for `R`. What it owns is the logbook: one
/// entry per [Entry].
///
/// Sending a prompt to a model is not the airlock's job: the agent loop
/// writes each turn to the logbook itself, and a model call's bytes are
/// written by whatever sends them, not by this package.
///
/// Nor does this package hold the logbook itself: `is_logbook`'s
/// one writer does, for every sender, and this is one of its senders.
///
/// Nor does it witness arrivals any more (Nick's ruling, 16 Nov): an
/// incoming event is written to the logbook by whoever puts it there, not by
/// the airlock — a tool's effect is the airlock's whole concern now.
library;

// A caller can't build an Airlock without writing `decide`, which
// returns a Decision (Allow, Deny, DecidedBy) over a Reach — so these are
// part of Airlock's interface in practice, not just its own. Dart
// only lets a caller import its own direct dependencies, and these
// packages are pinned here for reasons specific to this repo (see
// pubspec.yaml); re-exporting them keeps a caller from having to repeat
// that pin itself, with the two drifting apart if it ever changes here.
export 'package:is_airlock_api/is_airlock_api.dart';
export 'package:is_flight_rules/is_flight_rules.dart';
export 'package:is_file_request_vocabulary/is_file_request_vocabulary.dart';
export 'package:is_model_vocabulary/is_model_vocabulary.dart';
export 'package:is_outcome_vocabulary/is_outcome_vocabulary.dart';
export 'package:is_program_request_vocabulary/is_program_request_vocabulary.dart';
export 'package:is_relative_path_vocabulary/is_relative_path_vocabulary.dart';
export 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart';

export 'src/airlock.dart';
export 'src/airlock_subscriber.dart';
export 'src/decide_reach.dart';
export 'src/driver_release.dart';
export 'src/entry_index.dart';
export 'src/logbook_client.dart';
export 'src/model_driver_routing.dart';
export 'src/program_driver.dart';
export 'src/trajectory.dart';
export 'src/web_request_driver.dart';
