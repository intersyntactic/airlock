/// The airlock as its own service: a relay client (the Teams relay) that
/// cannot reach `is_journal`'s one writer service itself connects here
/// instead, and has its arrivals witnessed.
///
/// This binary holds no journal of its own: it is one of the writer
/// service's senders, over [RecordClient]. No code hash, no compiled-build
/// define — that concern belongs entirely to the writer service's own
/// build now.
///
/// Environment:
///   AIRLOCK_RECORD_SOCKET  the writer service's Unix socket
///                          (`is_journal`'s `JOURNAL_SOCKET`)
///   AIRLOCK_SOCKET_PATH    the Unix socket this service itself serves
///                          relay clients on (removed first if a stale
///                          one is there)
///   AIRLOCK_SOCKET_MODE    this service's own socket's permission bits,
///                          as `chmod` takes them; default `600` (owner
///                          only). The socket's group is whatever group
///                          this process runs as; a client in a
///                          different user grants itself access via a
///                          supplementary group (systemd
///                          `SupplementaryGroups=`), not a directory
///                          setting.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_airlock/src/record_client.dart';
import 'package:is_airlock/src/recorded_airlock.dart';
import 'package:is_airlock/src/witness_service.dart';

Future<void> main() async {
  final recordSocket = Platform.environment['AIRLOCK_RECORD_SOCKET'];
  final socketPath = Platform.environment['AIRLOCK_SOCKET_PATH'];
  if (recordSocket == null || socketPath == null) {
    stderr.writeln(
      'airlock service: set AIRLOCK_RECORD_SOCKET and AIRLOCK_SOCKET_PATH',
    );
    exitCode = 64;
    return;
  }

  final socketMode = Platform.environment['AIRLOCK_SOCKET_MODE'] ?? '600';
  final socketFile = File(socketPath);
  if (socketFile.existsSync()) socketFile.deleteSync();
  final server = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  await Process.run('chmod', [socketMode, socketPath]);
  stderr.writeln('airlock service: witnessing on $socketPath');

  final stopping = Completer<void>();
  final signals = [
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint])
      signal.watch().listen((_) {
        if (!stopping.isCompleted) stopping.complete();
      }),
  ];

  await WitnessService(Witness(RecordClient(recordSocket)))
      .serve(server, stop: stopping.future);

  // A signal's watch() stream has no natural end, so main() returning
  // would leave the VM with listeners still pending, never actually
  // exiting the process the signal was meant to stop.
  for (final s in signals) {
    await s.cancel();
  }
  await server.close();
  if (socketFile.existsSync()) socketFile.deleteSync();
  stderr.writeln('airlock service: stopped');
}
