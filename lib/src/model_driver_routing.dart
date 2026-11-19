import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:is_claude_code_driver/service.dart' show ClaudeCodeDriverSocket;
import 'package:is_effects/is_effects.dart';

/// Calls the model through whichever of [driversBySignIn] a call's sign-in
/// names, refusing a sign-in the map holds none for.
///
/// One driver per sign-in rather than one for the whole machine, since a
/// mission is admitted under whichever sign-in its rules name (Nick, 20
/// Nov: Claude Team by default, ChatGPT where a mission's source is mapped
/// to it), and each sign-in's secret lives with its own driver process.
final class RoutesModelCallsBySignIn implements AsksTheModel {
  const RoutesModelCallsBySignIn(this.driversBySignIn);

  /// [sockets]'s content read as sign-in -> driver socket path, one
  /// [ClaudeCodeDriverSocket] per entry: every model driver speaks the same
  /// wire protocol (is_claude_code_driver's own service.dart), so the one
  /// client type dials whichever socket its sign-in is routed to.
  factory RoutesModelCallsBySignIn.fromSocketsFile(String sockets) =>
      RoutesModelCallsBySignIn({
        for (final MapEntry(:key, :value) in socketPathsBySignIn(sockets).entries)
          key: ClaudeCodeDriverSocket(File(value)),
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

/// [sockets]'s content (a JSON object, sign-in name -> socket path) read
/// back strictly: a key that is not a sign-in's name, or a value that is
/// not a string, throws a [FormatException]. Split out from
/// [RoutesModelCallsBySignIn.fromSocketsFile] so the map's shape is
/// checkable without a socket to dial.
Map<ModelSignInName, String> socketPathsBySignIn(String sockets) {
  final object = JsonObject.decode(sockets);
  return {
    for (final key in object.keys) _signInNamed(key): object.string(key),
  };
}

ModelSignInName _signInNamed(String raw) =>
    ModelSignInName.parse(raw) ??
    (throw FormatException('$raw: not a sign-in name'));
