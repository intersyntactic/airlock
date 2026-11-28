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

Future<void> main() async {
  final logbookSocket = Platform.environment['AIRLOCK_LOGBOOK_SOCKET'];
  final logbookReadSocket = Platform.environment['AIRLOCK_LOGBOOK_READ_SOCKET'];
  final webDriverSocket = Platform.environment['AIRLOCK_WEB_DRIVER_SOCKET'];
  final modelDriverSockets =
      Platform.environment['AIRLOCK_MODEL_DRIVER_SOCKETS'];
  final webDriverUserName = Platform.environment['AIRLOCK_WEB_DRIVER_USER'];
  if (logbookSocket == null ||
      logbookReadSocket == null ||
      webDriverSocket == null ||
      modelDriverSockets == null ||
      webDriverUserName == null) {
    stderr.writeln(
      'airlock service: set AIRLOCK_LOGBOOK_SOCKET, '
      'AIRLOCK_LOGBOOK_READ_SOCKET, AIRLOCK_WEB_DRIVER_SOCKET, '
      'AIRLOCK_MODEL_DRIVER_SOCKETS and AIRLOCK_WEB_DRIVER_USER',
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
  final grants = GrantsReaches();
  final airlock = Airlock<FlightRules, PlaceInTrajectory>(
    LogbookClient(logbookSocket),
    decide: grants.decide,
    entryOn: entryIndex.entryOn,
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
    onTrajectoryStarted: grants.noteReplyEndpoint,
    // No writer wired for either reply kind: the airlock depends on no
    // `*_module` package (Nick's ruling, 28 Nov — a module writes its own
    // reply requests against is_airlock_api's WritesReplyRequests, outside
    // this process; where that code runs is still open). Teams' own
    // replies are unaffected — they go through agent_loop's
    // teams-reply-drawing and the ordinary MakesWebRequests grant, never
    // through this path.
    //
    // When pinned-body writers are wired here, build their collection as
    // `PinnedBodyReplyWriters.of(writers) ?? (throw StateError('two reply
    // writers claim one address'))` — a collision must stop the service,
    // not silently turn pinned replies off (airlock-api-b2, 28 Nov).
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

