/// The airlock as its own service: owns a journal and a Unix socket, and
/// witnesses what a client (a relay that cannot hold a journal itself)
/// sends it.
///
/// `is_journal` 0.3.0 can run compiled, given its code hash at build time:
///
///     dart compile exe $(dart run is_journal:code_hash) bin/airlock_service.dart
///
/// Run from source (`dart run`), no define is needed — `Journal.open`
/// computes the hash from its own source instead.
///
/// Environment:
///   AIRLOCK_JOURNAL_DIR  the journal's directory (created if absent)
///   AIRLOCK_SOCKET_PATH  the Unix socket path to serve on (removed first
///                        if a stale one is there; created with mode 600,
///                        so only a process able to read it, or one run
///                        as its owner, may connect — a systemd
///                        RuntimeDirectory with a narrower group is the
///                        intended deployment, not this alone)
library;

import 'dart:async';
import 'dart:io';

import 'package:is_airlock/src/recorded_airlock.dart';
import 'package:is_airlock/src/witness_service.dart';
import 'package:is_journal/is_journal.dart';

Future<void> main() async {
  final journalDir = Platform.environment['AIRLOCK_JOURNAL_DIR'];
  final socketPath = Platform.environment['AIRLOCK_SOCKET_PATH'];
  if (journalDir == null || socketPath == null) {
    stderr.writeln(
      'airlock service: set AIRLOCK_JOURNAL_DIR and AIRLOCK_SOCKET_PATH',
    );
    exitCode = 64;
    return;
  }

  final journal = Journal.open(Directory(journalDir));
  if (journal == null) {
    stderr.writeln(
      'airlock service: cannot name its own code (is_journal.ownHash); '
      'refusing to open a journal with no code hash',
    );
    exitCode = 1;
    return;
  }

  final socketFile = File(socketPath);
  if (socketFile.existsSync()) socketFile.deleteSync();
  final server = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  await Process.run('chmod', ['600', socketPath]);
  stderr.writeln('airlock service: witnessing on $socketPath');

  final stopping = Completer<void>();
  final signals = [
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint])
      signal.watch().listen((_) {
        if (!stopping.isCompleted) stopping.complete();
      }),
  ];

  await WitnessService(Witness(journal)).serve(server, stop: stopping.future);

  // A signal's watch() stream has no natural end, so main() returning
  // would leave the VM with listeners still pending, never actually
  // exiting the process the signal was meant to stop.
  for (final s in signals) {
    await s.cancel();
  }
  await server.close();
  journal.close();
  if (socketFile.existsSync()) socketFile.deleteSync();
  stderr.writeln('airlock service: stopped');
}
