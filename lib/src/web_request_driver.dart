import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

import 'driver_release.dart';

/// [CarriesOutWebRequests] in another process, over the wire the web
/// request driver speaks: connects to [socket], runs [checkDriver] on the
/// open connection before writing anything, sends the request, and reads
/// back the one answer line. Holds no secret.
///
/// Held here rather than imported from the web request driver's own
/// package, so a change to the driver's internals can't break the
/// airlock that never actually calls through it.
final class WebRequestDriverSocket implements CarriesOutWebRequests {
  /// [checkDriver] runs on every connection before the request is sent, so
  /// a driver it refuses never sees the request.
  WebRequestDriverSocket(this.socket, {this.checkDriver});

  final File socket;
  final CheckDriver? checkDriver;

  /// [NothingRan] only when the driver could not be reached, or refused the
  /// connection outright, so nothing was sent. Once the request is written
  /// to the driver's own socket (never the driver's own HTTP call, which
  /// this never sees), anything short of a decoded answer is
  /// [StoppedPartway] with `done: null`: the driver may have already made
  /// the request, and only it knows how far that got — never [NothingRan],
  /// which would wrongly promise it is safe to retry.
  @override
  Future<Outcome<WebResponse>> carryOutWebRequest(GrantedRequest request) async {
    final Socket s;
    try {
      s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      if (await checkDriver?.call(s) case final why?) {
        s.destroy();
        return NothingRan('web request driver: $why');
      }
    } on SocketException catch (e) {
      return NothingRan('web request driver: ${e.message}');
    }
    String? answer;
    try {
      s.add(utf8.encode(jsonEncode(encodeGrantedRequest(request))));
      await s.close();
      answer = await utf8.decoder.bind(s).join();
      if (answer.isEmpty) {
        return const StoppedPartway(why: 'web request driver: no answer', done: null);
      }
      return decodeOutcome(jsonDecode(answer), decodeWebResponse);
    } on SocketException catch (e) {
      return StoppedPartway(why: 'web request driver: ${e.message}', done: null);
    } on FormatException catch (e) {
      return StoppedPartway(
        why: 'undecodable answer from ${socket.path}: ${e.message}: $answer',
        done: null,
      );
    }
  }
}
