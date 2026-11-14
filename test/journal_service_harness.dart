/// Starts a real `is_journal:service` subprocess for tests to send to,
/// matching a8's ask: test the new wire protocol against the real thing,
/// not a reimplementation of it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A running `is_journal:service`, writing into its own temp directory.
final class JournalServiceHarness {
  JournalServiceHarness._(
    this.socketPath,
    this.journalDir,
    this._process,
    this._dir,
  );

  /// The socket a [RecordClient] connects to.
  final String socketPath;

  /// Where the service keeps its journal — for tests reading its raw
  /// `entries`/`objects` directly, the way `is_journal`'s own tests do.
  final Directory journalDir;

  final Process _process;
  final Directory _dir;

  /// Starts the service, granting this process's own user [kinds] to
  /// send. Waits for its "listening on" line before returning.
  static Future<JournalServiceHarness> start(List<String> kinds) async {
    final dir = Directory.systemTemp.createTempSync('journal_service_test_');
    final me = Process.runSync('id', ['-un']).stdout.toString().trim();
    final sendersFile = File('${dir.path}/senders')
      ..writeAsStringSync('$me ${kinds.join(' ')}\n');
    final socketPath = '${dir.path}/journal.sock';

    final journalDir = Directory('${dir.path}/journal');
    final process = await Process.start(
      'dart',
      ['run', 'is_journal:service'],
      environment: {
        'JOURNAL_DIR': journalDir.path,
        'JOURNAL_SOCKET': socketPath,
        'JOURNAL_SENDERS': sendersFile.path,
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
          StateError('is_journal:service exited $code: $errors'),
        );
      }
    });
    await Future.any([ready.future, exited]);

    return JournalServiceHarness._(socketPath, journalDir, process, dir);
  }

  Future<void> stop() async {
    _process.kill(ProcessSignal.sigterm);
    await _process.exitCode;
    _dir.deleteSync(recursive: true);
  }
}
