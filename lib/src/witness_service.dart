/// Serves [Witness.witness] over a local socket, so a process that cannot
/// hold a [Journal] of its own (because it is `dart compile exe`'d, and
/// `is_journal` cannot run compiled) can still have its arrivals witnessed.
///
/// One request, one response, one connection: a client sends a line of
/// JSON — `{"source": ..., "bytes": ...}` — and gets back a line of JSON,
/// `{"id": ...}` once the entry's `add` has returned, or `{"error": ...}`
/// on any failure. Never a success on a failure: a client that cannot
/// tell the two apart could go on as though something had been recorded
/// when nothing was.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_journal/is_journal.dart';

import 'arrival_source.dart';
import 'recorded_airlock.dart';

final class WitnessService {
  const WitnessService(this._witness);

  final Witness _witness;

  /// Serves connections from [server] until [stop] completes, then stops
  /// accepting new ones and waits for every connection already being
  /// handled to finish, before returning. Closing the journal is the
  /// caller's: this never does, so a connection still being handled when
  /// [stop] completes is never asked to record into one that has already
  /// given up its claim.
  Future<void> serve(ServerSocket server, {required Future<void> stop}) async {
    final handling = <Future<void>>{};
    final subscription = server.listen((socket) {
      final handled = _handle(socket);
      handling.add(handled);
      unawaited(handled.whenComplete(() => handling.remove(handled)));
    });
    await stop;
    await subscription.cancel();
    await Future.wait(handling);
  }

  Future<void> _handle(Socket socket) async {
    try {
      String? line;
      await for (final l
          in utf8.decoder.bind(socket).transform(const LineSplitter())) {
        line = l;
        break;
      }
      if (line == null) {
        _respond(socket, error: 'closed before sending a request');
        return;
      }
      final request = JsonObject.decode(line);
      final source = ArrivalSource.parse(request.string('source'));
      if (source == null) {
        _respond(socket, error: 'not a source');
        return;
      }
      final bytes = base64Decode(request.string('bytes'));
      _respond(socket, id: _witness.witness(bytes, source: source));
    } on Exception catch (e) {
      _respond(socket, error: '$e');
    } finally {
      await socket.close();
    }
  }

  void _respond(Socket socket, {ObjectId? id, String? error}) {
    socket.add(
      utf8.encode(
        '${jsonEncode(id != null ? {'id': id.hex} : {'error': error})}\n',
      ),
    );
  }
}
