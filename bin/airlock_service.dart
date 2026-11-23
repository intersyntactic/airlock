/// The airlock as its own service: subscribes to the logbook, builds a
/// [Trajectory] per path from its `event-admitted-to-mission` and
/// `users-assigned-to-trajectory` entries, and reacts to each `proposed`
/// entry on a trajectory's own chain.
///
/// "The airlock has no door of its own" (is_airlock_api 0.7.1): there is no
/// listener here for a loop to dial. A loop only ever proposes through the
/// logbook.
///
/// Environment:
///   AIRLOCK_LOGBOOK_SOCKET      the writer service's Unix socket
///   AIRLOCK_LOGBOOK_READ_SOCKET the writer service's read/subscribe
///                               socket
///   AIRLOCK_WEB_DRIVER_SOCKET   the web driver's Unix socket
///   AIRLOCK_MODEL_DRIVER_SOCKETS a JSON object's path, sign-in name ->
///     `{"socket": ..., "user": ...}` — that sign-in's model driver's Unix
///     socket, and the process user it must be running as, checked the
///     same way as AIRLOCK_WEB_DRIVER_USER: a release must not check less
///     than what is already live. The user lives in the same entry as the
///     socket, never a second map beside it, so a sign-in can't have one
///     without the other.
///   AIRLOCK_TEAMS_SIGN_IN       which sign-in posts a Teams reply or the
///                               trajectory-opened card (operational, not
///                               a build: infra's call which name CAM's
///                               Teams sign-in actually has)
///   AIRLOCK_PROPOSALS_ENABLED   `1` or `true` once infra-5e has confirmed
///                               the logbook enforces that a trajectory's
///                               chain takes entries only from its own loop
///                               user; unset or anything else means no
///                               `proposed` entry is acted on — flag only,
///                               no version check.
///   AIRLOCK_WEB_DRIVER_USER     the web driver's own process's user, by
///                               name or numeric uid, checked against the
///                               kernel's own report of who connects
///                               (`is_unix_socket_user_check`) — required,
///                               not derived from the socket file, which
///                               would trust whoever created the file
///                               first rather than something independent
///                               of the driver it checks. Each routed model
///                               driver gets the same check, its own user
///                               named in AIRLOCK_MODEL_DRIVER_SOCKETS.
///   AIRLOCK_WEB_DRIVER_RELEASE  optional: infra's own `<sha>-<digest>`
///                               release id (`DriverRelease.parseExpected`)
///                               for the release the web driver's socket is
///                               expected to be running. Unset means no
///                               release is checked — only its user.
///                               Pinned exactly: changing the web driver's
///                               release means changing this var in the
///                               same deploy, or the airlock refuses every
///                               one of its requests until it does.
library;

import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_logbook_client/is_logbook_client.dart' show LogbookReader;
import 'package:is_teams_module/is_teams_module.dart'
    show TeamsRequestsAnsweringEvents;

Future<void> main() async {
  final logbookSocket = Platform.environment['AIRLOCK_LOGBOOK_SOCKET'];
  final logbookReadSocket = Platform.environment['AIRLOCK_LOGBOOK_READ_SOCKET'];
  final webDriverSocket = Platform.environment['AIRLOCK_WEB_DRIVER_SOCKET'];
  final modelDriverSockets =
      Platform.environment['AIRLOCK_MODEL_DRIVER_SOCKETS'];
  final teamsSignInName = Platform.environment['AIRLOCK_TEAMS_SIGN_IN'];
  final webDriverUserName = Platform.environment['AIRLOCK_WEB_DRIVER_USER'];
  if (logbookSocket == null ||
      logbookReadSocket == null ||
      webDriverSocket == null ||
      modelDriverSockets == null ||
      teamsSignInName == null ||
      webDriverUserName == null) {
    stderr.writeln(
      'airlock service: set AIRLOCK_LOGBOOK_SOCKET, '
      'AIRLOCK_LOGBOOK_READ_SOCKET, AIRLOCK_WEB_DRIVER_SOCKET, '
      'AIRLOCK_MODEL_DRIVER_SOCKETS, AIRLOCK_TEAMS_SIGN_IN and '
      'AIRLOCK_WEB_DRIVER_USER',
    );
    exitCode = 64;
    return;
  }
  // A restart cannot fix a bad user or release id either, so every one of
  // these failures ends the same way as the block above: systemd's own
  // unit file stops restart-looping on exit 64 specifically
  // (RestartPreventExitStatus=64), never on an uncaught exception's exit.
  final webDriverUser = userNamedBy(webDriverUserName);
  if (webDriverUser == null) {
    stderr.writeln(
      'airlock service: AIRLOCK_WEB_DRIVER_USER must name a real user, '
      'by name or id — not unset, not the kernel\'s overflow uid or '
      'nobody',
    );
    exitCode = 64;
    return;
  }
  final webDriverRelease = _expectedRelease('AIRLOCK_WEB_DRIVER_RELEASE');
  if (!webDriverRelease.ok) {
    stderr.writeln(
      'airlock service: AIRLOCK_WEB_DRIVER_RELEASE, when set, must be a '
      'release id ("<sha>-<digest>")',
    );
    exitCode = 64;
    return;
  }
  final teamsSignIn =
      SignIn.parse(teamsSignInName) ??
      (throw StateError('AIRLOCK_TEAMS_SIGN_IN: not a sign-in name'));
  final RoutesModelCallsBySignIn modelDriver;
  try {
    modelDriver = RoutesModelCallsBySignIn.fromSocketsFile(
      File(modelDriverSockets).readAsStringSync(),
    );
  } on FormatException catch (e) {
    stderr.writeln('airlock service: AIRLOCK_MODEL_DRIVER_SOCKETS: ${e.message}');
    exitCode = 64;
    return;
  }

  final entryIndex = EntryIndex();
  final airlock = Airlock<WhatMayLeaveThisMachine, PlaceInTrajectory>(
    LogbookClient(logbookSocket),
    decide: _decide,
    entryOn: entryIndex.entryOn,
    rawEntry: entryIndex.raw,
    registryByScheme: {
      ExternalSystemScheme.parse('teams')!: (
        module: const TeamsRequestsAnsweringEvents(),
        signIn: teamsSignIn,
      ),
    },
  );

  final proposalsEnabled = switch (
      // wire-ok: an environment variable, a boundary string
      Platform.environment['AIRLOCK_PROPOSALS_ENABLED']?.toLowerCase()) {
    '1' || 'true' => true,
    _ => false,
  };
  stderr.writeln(
    'airlock service: subscribing to $logbookReadSocket '
    '(proposals ${proposalsEnabled ? 'enabled' : 'disabled'})',
  );
  await runAirlockService(
    subscribe: () => LogbookReader(logbookReadSocket).subscribe(),
    airlock: airlock,
    drivers: [
      WebRequestDriverSocket(
        File(webDriverSocket),
        checkDriver: checkDriverRelease(
          expectedUser: webDriverUser,
          expected: webDriverRelease.release,
        ),
      ),
      modelDriver,
    ],
    proposalsEnabled: proposalsEnabled,
    entryIndex: entryIndex,
    writeRejection: airlock.writeRejection,
    writeLogbookEntry: airlock.writeLogbookEntry,
    say: stderr.writeln,
  );
}

/// The release named by the env var [name]: [release] is null when the var
/// is unset (deliberately means "don't check"), and [ok] is false only
/// when it was set but unparseable — a startup failure, not a silently
/// ignored typo.
({DriverRelease? release, bool ok}) _expectedRelease(String name) {
  final value = Platform.environment[name];
  if (value == null) return (release: null, ok: true);
  final release = DriverRelease.parseExpected(value);
  return (release: release, ok: release != null);
}

/// Files, writes and programs carry nothing off this machine by
/// themselves, so none needs a rule here (`WhatMayLeaveThisMachine`'s own
/// doc comment); only a web request or a model call does.
Decision _decide(
  TrajectoryId trajectory,
  Reach reach,
  WhatMayLeaveThisMachine rules,
) => switch (reach) {
  Reads() || Writes() || Starts() => const Allow(by: DecidedBy.rules),
  AnswersEvent(:final requests) => _grantEach(rules, requests),
  FetchesFromWeb(:final origin, :final signIn) => _grant(rules, origin, signIn),
  CallsTheModel(:final signIn) => rules.allowsModelCall(signIn)
      ? const Allow(by: DecidedBy.rules)
      : Deny('not granted: model calls as $signIn', by: DecidedBy.rules),
};

/// Every one of [requests] granted together: an [AnswersEvent] sends them
/// all or none, so the first missing grant denies the whole reach.
Decision _grantEach(WhatMayLeaveThisMachine rules, List<Request> requests) {
  for (final request in requests) {
    final decision = _grant(rules, request.origin, request.signIn);
    if (decision is Deny) return decision;
  }
  return const Allow(by: DecidedBy.rules);
}

/// Whether [rules] grants a request to [origin] as [signIn]. Nothing is
/// relied on beyond the rules yet: `leasedNow` and `pooled` are both empty
/// until loop_launcher's lease-tracking entries exist (task 49) — verified
/// against is_flight_rules 0.3.0's own source that an empty `leasedNow`/
/// `pooled` behaves exactly as the old `allowsWebRequest` did.
Decision _grant(WhatMayLeaveThisMachine rules, Origin origin, SignIn? signIn) =>
    switch (rules.grantFor(
      origin,
      signIn,
      leasedNow: const {},
      pooled: const {},
    )) {
      null => Deny(
        'not granted: $origin as ${signIn ?? 'no sign-in'}',
        by: DecidedBy.rules,
      ),
      _ => const Allow(by: DecidedBy.rules),
    };
