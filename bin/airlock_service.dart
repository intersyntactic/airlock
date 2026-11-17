/// The airlock as its own service: subscribes to the record, builds a
/// [Trajectory] per path from its `event-admitted-to-mission` and
/// `users-assigned-to-trajectory` entries, and reacts to each `proposed`
/// entry on a trajectory's own chain.
///
/// "The airlock has no door of its own" (is_airlock_api 0.7.1): there is no
/// listener here for a loop to dial. A loop only ever proposes through the
/// record.
///
/// Environment:
///   AIRLOCK_RECORD_SOCKET       the writer service's Unix socket
///   AIRLOCK_RECORD_READ_SOCKET  the writer service's read/subscribe socket
///   AIRLOCK_WEB_DRIVER_SOCKET   the web driver's Unix socket
///   AIRLOCK_PROPOSALS_ENABLED   `1` or `true` once infra-5e has confirmed
///                               the record enforces that a trajectory's
///                               chain takes entries only from its own loop
///                               user; unset or anything else means no
///                               `proposed` entry is acted on (task 20,
///                               Nick's call — flag only, no version check).
library;

import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_journal_client/is_journal_client.dart' show JournalReader;
import 'package:is_web_driver/service.dart' show WebDriverSocket;

Future<void> main() async {
  final recordSocket = Platform.environment['AIRLOCK_RECORD_SOCKET'];
  final readSocket = Platform.environment['AIRLOCK_RECORD_READ_SOCKET'];
  final webDriverSocket = Platform.environment['AIRLOCK_WEB_DRIVER_SOCKET'];
  if (recordSocket == null || readSocket == null || webDriverSocket == null) {
    stderr.writeln(
      'airlock service: set AIRLOCK_RECORD_SOCKET, '
      'AIRLOCK_RECORD_READ_SOCKET and AIRLOCK_WEB_DRIVER_SOCKET',
    );
    exitCode = 64;
    return;
  }

  final airlock = RecordedAirlock<WhatMayLeaveThisMachine, Place>(
    RecordClient(recordSocket),
    decide: _decide,
    // No renderer registry yet (task 27/22): every web request is denied
    // for naming no renderer, before rules are even asked.
    renderer: (name) async => null,
    rendered: (decided) async =>
        const Refused('renderer not wired yet (task 27)'),
  );

  final proposalsEnabled = switch (
      Platform.environment['AIRLOCK_PROPOSALS_ENABLED']?.toLowerCase()) {
    '1' || 'true' => true,
    _ => false,
  };
  stderr.writeln(
    'airlock service: subscribing to $readSocket '
    '(proposals ${proposalsEnabled ? 'enabled' : 'disabled'})',
  );
  await runAirlockService(
    subscribe: () => JournalReader(readSocket).subscribe(),
    airlock: airlock,
    drivers: [WebDriverSocket(File(webDriverSocket))],
    proposalsEnabled: proposalsEnabled,
    say: stderr.writeln,
  );
}

/// Files, writes and programs carry nothing off this machine by
/// themselves, so none needs a rule here (`WhatMayLeaveThisMachine`'s own
/// doc comment); only a web request does.
Decision _decide(Reach reach, WhatMayLeaveThisMachine rules) => switch (reach) {
  Reads() || Writes() || Starts() => const Allow(by: DecidedBy.rules),
  MakesWebRequest(:final request) => rules.allowsWebRequest(
    request.origin,
    request.signIn,
  )
      ? const Allow(by: DecidedBy.rules)
      : Deny(
          'not granted: ${request.origin} as '
          '${request.signIn ?? 'no sign-in'}',
          by: DecidedBy.rules,
        ),
};
