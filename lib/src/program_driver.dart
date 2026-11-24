import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

import 'driver_release.dart';

/// [RunsPrograms] and [ListsInstalledPrograms] in another process, over the
/// wire the program driver speaks: connects to [socket], runs [checkDriver]
/// on the open connection before writing anything, sends the request, then
/// reports each streamed message and returns the final one's outcome.
/// Holds no secret.
///
/// Held here rather than imported from the program driver's own package, so
/// a change to the driver's internals can't break the airlock that never
/// actually calls through it.
final class ProgramDriverSocket implements RunsPrograms, ListsInstalledPrograms {
  /// [checkDriver] runs on every connection before the request is sent, so
  /// a driver it refuses never sees it.
  ProgramDriverSocket(this.socket, {this.checkDriver});

  final File socket;
  final CheckDriver? checkDriver;

  /// The programs the driver runs, as it loaded them when it started.
  /// Throws [InstalledProgramsUnknown] when it cannot be asked or does not
  /// answer with them.
  @override
  Future<Set<ProgramName>> installedPrograms() async {
    try {
      final s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      if (await checkDriver?.call(s) case final why?) {
        s.destroy();
        throw InstalledProgramsUnknown('program driver: $why');
      }
      s.add(
        utf8.encode(
          jsonEncode(encodeProgramRequest(const ListInstalledProgramsRequest())),
        ),
      );
      await s.close();
      final answer = await utf8.decoder.bind(s).join();
      if (answer.isEmpty) {
        throw const InstalledProgramsUnknown('program driver: refused caller');
      }
      return decodeProgramNames(jsonDecode(answer));
    } on SocketException catch (e) {
      throw InstalledProgramsUnknown('program driver: ${e.message}');
    } on FormatException catch (e) {
      throw InstalledProgramsUnknown('program driver: unreadable answer: ${e.message}');
    }
  }

  /// [NothingRan] only when the driver could not be reached, or refused the
  /// connection outright, so nothing was sent. Once the request to run
  /// [program] is sent, a run that ends without its [Finished] is
  /// [StoppedPartway] with `done: null`: the program may have started, even
  /// having printed nothing, and may still be running, and only the driver
  /// knows — never [NothingRan], which would wrongly promise it is safe to
  /// retry.
  @override
  Future<Outcome<ExecResult>> runProgram(
    ProgramName program,
    Args args, {
    required Report report,
  }) async {
    final Socket s;
    try {
      s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      if (await checkDriver?.call(s) case final why?) {
        s.destroy();
        return NothingRan('program driver: $why');
      }
    } on SocketException catch (e) {
      return NothingRan('program driver: ${e.message}');
    }
    String? lastLine;
    try {
      s.add(
        utf8.encode(
          jsonEncode(encodeProgramRequest(RunProgramRequest(program, args))),
        ),
      );
      await s.close();
      await for (final line
          in utf8.decoder.bind(s).transform(const LineSplitter())) {
        lastLine = line;
        switch (decodeProgramMessage(jsonDecode(line), decodeExecResult)) {
          case Reported(:final progress):
            report(progress);
          case Finished(:final outcome):
            return outcome;
        }
      }
      return const StoppedPartway(
        why: 'program driver: the connection closed before it finished',
        done: null,
      );
    } on SocketException catch (e) {
      return StoppedPartway(why: 'program driver: ${e.message}', done: null);
    } on FormatException catch (e) {
      return StoppedPartway(
        why: 'program driver: unreadable answer: ${e.message}: $lastLine',
        done: null,
      );
    }
  }
}

/// The driver was asked which programs it runs and did not say, because
/// [why].
final class InstalledProgramsUnknown implements Exception {
  const InstalledProgramsUnknown(this.why);

  final String why;

  @override
  String toString() => 'installed programs unknown: $why';
}
