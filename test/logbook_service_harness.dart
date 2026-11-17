/// Starts a real `is_logbook:service` subprocess for tests to send to,
/// matching a8's ask: test the new wire protocol against the real thing,
/// not a reimplementation of it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A running `is_logbook:service`, writing into its own temp directory.
final class LogbookServiceHarness {
  LogbookServiceHarness._(
    this.socketPath,
    this.readSocketPath,
    this.journalDir,
    this._process,
    this._dir,
  );

  /// The socket a [RecordClient] connects to.
  final String socketPath;

  /// The socket `get`/`tip`/`follow` connect to, null unless [start] was
  /// asked for one.
  final String? readSocketPath;

  /// Where the service keeps its logbook — for tests reading its raw
  /// `entries`/`objects` directly, the way `is_logbook`'s own tests do.
  final Directory journalDir;

  final Process _process;
  final Directory _dir;

  /// Starts the service, granting this process's own user [kinds] to
  /// send, and a read socket too when [withReadSocket]. Waits for its
  /// "listening on" line before returning.
  static Future<LogbookServiceHarness> start(
    List<String> kinds, {
    bool withReadSocket = false,
  }) async {
    final dir = Directory.systemTemp.createTempSync('logbook_service_test_');
    final me = Process.runSync('id', ['-un']).stdout.toString().trim();
    final sendersFile = File('${dir.path}/senders')
      ..writeAsStringSync('$me ${kinds.join(' ')}\n');
    final socketPath = '${dir.path}/logbook.sock';
    final readSocketPath = withReadSocket ? '${dir.path}/logbook-read.sock' : null;

    final journalDir = Directory('${dir.path}/logbook');
    final process = await Process.start(
      'dart',
      ['run', 'is_logbook:service'],
      environment: {
        'LOGBOOK_DIR': journalDir.path,
        'LOGBOOK_SOCKET': socketPath,
        'LOGBOOK_SENDERS': sendersFile.path,
        if (readSocketPath != null) 'LOGBOOK_READ_SOCKET': readSocketPath,
      },
    );

    final ready = Completer<void>();
    final errors = StringBuffer();
    process.stdout.transform(utf8.decoder).listen((line) {
      if (!ready.isCompleted && line.contains('listening on')) {
        ready.complete();
      }
    });
    process.stderr.transform(utf8.decoder).listen(errors.write);
    final exited = process.exitCode.then((code) {
      if (!ready.isCompleted) {
        ready.completeError(
          StateError('is_logbook:service exited $code: $errors'),
        );
      }
    });
    await Future.any([ready.future, exited]);

    return LogbookServiceHarness._(
      socketPath,
      readSocketPath,
      journalDir,
      process,
      dir,
    );
  }

  Future<void> stop() async {
    _process.kill(ProcessSignal.sigterm);
    await _process.exitCode;
    _dir.deleteSync(recursive: true);
  }
}
