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

  @override
  Future<Outcome<WebResponse>> carryOutWebRequest(GrantedRequest request) async {
    try {
      final s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      if (await checkDriver?.call(s) case final why?) {
        s.destroy();
        return Refused('web request driver: $why');
      }
      s.add(utf8.encode(jsonEncode(encodeGrantedRequest(request))));
      await s.close();
      final answer = await utf8.decoder.bind(s).join();
      if (answer.isEmpty) {
        return const Refused('web request driver: refused caller');
      }
      return decodeOutcome(jsonDecode(answer), decodeWebResponse);
    } on SocketException catch (e) {
      return Refused('web request driver: ${e.message}');
    } on FormatException catch (e) {
      return Refused('web request driver: unreadable answer: ${e.message}');
    }
  }
}
