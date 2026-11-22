import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_claude_code_driver/service.dart' show ClaudeCodeDriverSocket;
import 'package:is_effects/is_effects.dart';

import 'driver_release.dart';

/// Calls the model through whichever of [driversBySignIn] a call's sign-in
/// names, refusing a sign-in the map holds none for.
///
/// One driver per sign-in rather than one for the whole machine, since a
/// mission is admitted under whichever sign-in its rules name (Nick, 20
/// Nov: Claude Team by default, ChatGPT where a mission's source is mapped
/// to it), and each sign-in's secret lives with its own driver process.
final class RoutesModelCallsBySignIn implements AsksTheModel {
  const RoutesModelCallsBySignIn(this.driversBySignIn);

  /// [sockets]'s content read as sign-in -> driver, one
  /// [ClaudeCodeDriverSocket] per entry: every model driver speaks the same
  /// wire protocol (is_claude_code_driver's own service.dart), so the one
  /// client type dials whichever socket its sign-in is routed to, checked
  /// against that entry's own expected user first — exactly as
  /// [AIRLOCK_WEB_DRIVER_USER] checks the web driver (Nick's ruling, 22
  /// Nov: a release must not check less than what is already live).
  ///
  /// Throws [FormatException] for a malformed entry, including a [user]
  /// that is not a real user by name or id — the same restart-cannot-fix-it
  /// failure `bin/airlock_service.dart` already exits 64 on for the web
  /// driver's own user.
  factory RoutesModelCallsBySignIn.fromSocketsFile(String sockets) =>
      RoutesModelCallsBySignIn({
        for (final MapEntry(:key, :value) in modelDriversBySignIn(sockets).entries)
          key: ClaudeCodeDriverSocket(
            File(value.socket),
            checkDriver: checkDriverRelease(
              expectedUser: userNamedBy(value.user) ??
                  (throw FormatException(
                    '$key: user "${value.user}" is not a real user, by name or id',
                  )),
            ),
          ),
      });

  final Map<ModelSignInName, AsksTheModel> driversBySignIn;

  @override
  Future<Outcome<ModelReply>> askTheModel(
    ModelSignInName signIn,
    ModelName model,
    String systemPrompt,
    String request, {
    required Report report,
  }) async {
    final driver = driversBySignIn[signIn];
    if (driver == null) return Refused('no model driver for sign-in $signIn');
    return driver.askTheModel(signIn, model, systemPrompt, request, report: report);
  }
}

/// [sockets]'s content (a JSON object, sign-in name -> `{"socket":
/// ..., "user": ...}`) read back strictly: a key that is not a sign-in's
/// name, or an entry missing either field as a string, throws a
/// [FormatException]. A sign-in's user lives in the same entry as its
/// socket, not a second map alongside it, so one can never be configured
/// without the other. Split out from
/// [RoutesModelCallsBySignIn.fromSocketsFile] so the map's shape is
/// checkable without a socket to dial or a user to resolve.
Map<ModelSignInName, ({String socket, String user})> modelDriversBySignIn(
  String sockets,
) {
  final object = JsonObject.decode(sockets);
  return {
    for (final key in object.keys) _signInNamed(key): _driverEntry(object.object(key)),
  };
}

({String socket, String user}) _driverEntry(JsonObject entry) =>
    (socket: entry.string('socket'), user: entry.string('user'));

ModelSignInName _signInNamed(String raw) =>
    ModelSignInName.parse(raw) ??
    (throw FormatException('$raw: not a sign-in name'));
