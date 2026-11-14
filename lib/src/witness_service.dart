/// Serves [Witness.witness] over a local socket, so a process that cannot
/// reach `is_journal`'s one writer service directly — the Teams relay, at
/// least for now — can still have its arrivals witnessed.
///
/// One request, one response, one connection: a client sends a line of
/// JSON — `{"source": ..., "bytes": ...}` — and gets back a line of JSON,
/// `{"id": ...}` once the writer has answered `ok`, or `{"error": ...}`
/// on any failure. Never a success on a failure: a client that cannot
/// tell the two apart could go on as though something had been recorded
/// when nothing was.
///
/// A [RecordFailed] is answered with `{"error": ..., "retry": false}`:
/// the entry may be in while its object is not, so a client must not
/// retry the same request — doing so could record the arrival twice.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';

import 'arrival_source.dart';
import 'record_client.dart';
import 'recorded_airlock.dart';

final class WitnessService {
  const WitnessService(this._witness);

  final Witness _witness;

  /// Serves connections from [server] until [stop] completes, then stops
  /// accepting new ones and waits for every connection already being
  /// handled to finish, before returning.
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
      final hash = await _witness.witness(bytes, source: source);
      _respond(socket, id: hash.hex);
    } on RecordFailed catch (e) {
      _respond(socket, error: '$e', retry: false);
    } on Exception catch (e) {
      _respond(socket, error: '$e');
    } finally {
      await socket.close();
    }
  }

  void _respond(Socket socket, {String? id, String? error, bool? retry}) {
    socket.add(
      utf8.encode(
        '${jsonEncode(id != null ? {'id': id} : {'error': error, if (retry != null) 'retry': retry})}\n',
      ),
    );
  }
}
