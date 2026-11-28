import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:test/test.dart';

final _git = ProgramName.parse('git')!;
const _args = Args(['status']);

void main() {
  group('ProgramDriverSocket, over a real Unix domain socket', () {
    late Directory directory;
    ServerSocket? server;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('program_driver_test');
    });

    tearDown(() async {
      await server?.close();
      await directory.delete(recursive: true);
    });

    /// Binds a server that answers the one connection it accepts with
    /// [answer]'s own raw text (no trailing newline added — callers that
    /// want one include it), after draining whatever the client sent.
    /// [onRequest] fires once the request has been fully received, so a
    /// test can tell whether the driver ever reached this point.
    Future<File> serverAnswering(
      String answer, {
      void Function()? onRequest,
    }) async {
      final socket = File('${directory.path}/driver.sock');
      final address = InternetAddress(
        socket.path,
        type: InternetAddressType.unix,
      );
      final bound = await ServerSocket.bind(address, 0);
      server = bound;
      bound.listen((client) async {
        await client.drain<void>();
        onRequest?.call();
        client.add(utf8.encode(answer));
        await client.close();
      });
      return socket;
    }

    group('runProgram', () {
      test('a driver the check refuses never sees the request', () async {
        var sawRequest = false;
        final socket = await serverAnswering(
          '',
          onRequest: () => sawRequest = true,
        );

        final result = await ProgramDriverSocket(
          socket,
          checkDriver: (_) async => 'not the expected driver',
        ).runProgram(_git, _args, report: (_) {});

        expect(result, isA<NothingRan>());
        expect((result as NothingRan).why, contains('not the expected driver'));
        expect(sawRequest, isFalse);
      });

      test('reports progress, then returns the Finished outcome', () async {
        final progress = <Printed>[];
        final socket = await serverAnswering(
          '${jsonEncode(encodeProgramMessage(const Reported<Printed, ExecResult>(Printed(Channel.stdout, 'on branch main')), encodePrinted, encodeExecResult))}\n'
          '${jsonEncode(encodeProgramMessage(Finished<Printed, ExecResult>(Ran(const Exited(0, stdout: 'on branch main', stderr: ''))), encodePrinted, encodeExecResult))}\n',
        );

        final result = await ProgramDriverSocket(
          socket,
        ).runProgram(_git, _args, report: progress.add);

        expect(progress, [isA<Printed>()]);
        expect(result, isA<Ran<ExecResult>>());
        expect(
          ((result as Ran<ExecResult>).output as Exited).exitCode,
          0,
        );
      });

      test(
        'a connection that ends before Finished is StoppedPartway with '
        'done: null, not NothingRan — the run may have started',
        () async {
          final socket = await serverAnswering('');

          final result = await ProgramDriverSocket(
            socket,
          ).runProgram(_git, _args, report: (_) {});

          expect(result, isA<StoppedPartway<ExecResult>>());
          expect((result as StoppedPartway<ExecResult>).done, isNull);
        },
      );

      test('NothingRan when no service is listening', () async {
        final socket = File('${directory.path}/nothing.sock');

        final result = await ProgramDriverSocket(
          socket,
        ).runProgram(_git, _args, report: (_) {});

        expect(result, isA<NothingRan>());
      });
    });

    group('installedPrograms', () {
      test('answers the programs the driver names', () async {
        final socket = await serverAnswering(
          '${jsonEncode(encodeProgramNames({_git, ProgramName.parse('ls')!}))}\n',
        );

        final result = await ProgramDriverSocket(socket).installedPrograms();

        expect(result, {_git, ProgramName.parse('ls')});
      });

      test('throws InstalledProgramsUnknown when no service is listening', () async {
        final socket = File('${directory.path}/nothing.sock');

        expect(
          () => ProgramDriverSocket(socket).installedPrograms(),
          throwsA(isA<InstalledProgramsUnknown>()),
        );
      });

      test('a driver the check refuses never sees the request', () async {
        var sawRequest = false;
        final socket = await serverAnswering(
          '',
          onRequest: () => sawRequest = true,
        );

        expect(
          () => ProgramDriverSocket(
            socket,
            checkDriver: (_) async => 'not the expected driver',
          ).installedPrograms(),
          throwsA(
            isA<InstalledProgramsUnknown>().having(
              (e) => e.why,
              'why',
              contains('not the expected driver'),
            ),
          ),
        );
        expect(sawRequest, isFalse);
      });
    });
  });
}
