/// Runs a real `is_logbook:service` in-process, the way `is_logbook_client`'s
/// own tests do: a real [LogbookService] over real Unix sockets, matching
/// a8's ask (test the new wire protocol against the real thing, not a
/// reimplementation of it) without needing real OS accounts for whatever
/// [LogbookService.start]'s own `uidOf` check is given to resolve.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';

/// A running [LogbookService], writing into its own temp directory.
final class LogbookServiceHarness {
  LogbookServiceHarness._(
    this.socketPath,
    this.readSocketPath,
    this.journalDir,
    this._service,
    this._dir,
  );

  /// The socket a [RecordClient] connects to.
  final String socketPath;

  /// The socket `get`/`tip`/`subscribe` connect to, null unless [start] was
  /// asked for one.
  final String? readSocketPath;

  /// Where the service keeps its logbook — for tests reading its raw
  /// `entries`/`objects` directly, the way `is_logbook`'s own tests do.
  final Directory journalDir;

  final LogbookService _service;
  final Directory _dir;

  /// The [Logbook] the service itself has open — for a test that wants to
  /// read it directly (`check()`, say), since a second [Logbook.open] on
  /// the same directory, in the same process, is refused.
  Logbook get logbook => _service.logbook;

  /// Starts the service, granting this process's own user [kinds] to
  /// send, and a read socket too when [withReadSocket]. [uidOf] answers
  /// [LogbookService.start]'s own check that `users-assigned-to-trajectory`
  /// names real users — a map of made-up uids for the loop/suit names a
  /// test writes, rather than real OS accounts.
  static Future<LogbookServiceHarness> start(
    List<String> kinds, {
    bool withReadSocket = false,
    int? Function(String user)? uidOf,
  }) async {
    final dir = Directory.systemTemp.createTempSync('logbook_service_test_');
    final me = Process.runSync('id', ['-un']).stdout.toString().trim();
    final senders = SenderTable.parse(
      Uint8List.fromList(utf8.encode('$me ${kinds.join(' ')}\n')),
    );
    final socketPath = '${dir.path}/logbook.sock';
    final readSocketPath = withReadSocket
        ? '${dir.path}/logbook-read.sock'
        : null;

    final journalDir = Directory('${dir.path}/logbook');
    final logbook = Logbook.open(journalDir)!;
    final service = await LogbookService.start(
      logbook,
      senders,
      File(socketPath),
      readSocket: readSocketPath == null ? null : File(readSocketPath),
      uidOf: uidOf ?? _uidOfUser,
    );

    return LogbookServiceHarness._(
      socketPath,
      readSocketPath,
      journalDir,
      service,
      dir,
    );
  }

  Future<void> stop() async {
    await _service.close();
    _dir.deleteSync(recursive: true);
  }
}

int? _uidOfUser(String user) {
  if (int.tryParse(user) case final uid?) return uid;
  final r = Process.runSync('id', ['-u', user]);
  return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
}
