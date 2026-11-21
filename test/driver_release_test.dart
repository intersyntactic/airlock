import 'dart:io';

import 'package:is_airlock/is_airlock.dart';
import 'package:test/test.dart';

void main() {
  group('DriverRelease.parse', () {
    test('reads the web driver\'s pre-cutover slice (01:49 UTC 20 Nov)', () {
      final release = DriverRelease.parse(
        '0::/system.slice/system-release_'
        '3558f2af5d1611727dc0e33906dd858008dd112d_54746c8a36e6.slice/'
        'intersyntactic-web-driver.service\n',
      );
      expect(release, isNotNull);
      expect(release!.sha, '3558f2af5d1611727dc0e33906dd858008dd112d');
      expect(release.digest, '54746c8a36e6');
      expect(release.unit, 'web-driver');
    });

    test('reads the web driver\'s post-cutover slice (22:26 UTC 20 Nov)', () {
      final release = DriverRelease.parse(
        '0::/system.slice/system-release_'
        '7cf5006359c68f657b34ae4fbc845920987585f1_54746c8a36e6.slice/'
        'intersyntactic-web-driver.service\n',
      );
      expect(release!.sha, '7cf5006359c68f657b34ae4fbc845920987585f1');
      expect(release.digest, '54746c8a36e6');
    });

    test('reads the airlock\'s own post-cutover slice (22:26 UTC 20 Nov)', () {
      final release = DriverRelease.parse(
        '0::/system.slice/system-release_'
        '61e8d64d2d4d959b9a5ed8f6bb03d05bb8f56da5_97e96324e989.slice/'
        'intersyntactic-airlock.service\n',
      );
      expect(release!.sha, '61e8d64d2d4d959b9a5ed8f6bb03d05bb8f56da5');
      expect(release.digest, '97e96324e989');
      expect(release.unit, 'airlock');
    });

    test('the same sha with a different digest is a different release', () {
      final a = DriverRelease.parse(
        '0::/system.slice/system-release_'
        '3558f2af5d1611727dc0e33906dd858008dd112d_54746c8a36e6.slice/'
        'intersyntactic-web-driver.service\n',
      )!;
      final b = DriverRelease.parse(
        '0::/system.slice/system-release_'
        '3558f2af5d1611727dc0e33906dd858008dd112d_000000000000.slice/'
        'intersyntactic-web-driver.service\n',
      )!;
      expect(a.matches(b), isFalse);
    });

    test('finds the unified-hierarchy line among others, cgroup v1 style', () {
      final release = DriverRelease.parse(
        '12:pids:/system.slice/intersyntactic-web-driver.service\n'
        '0::/system.slice/system-release_'
        '3558f2af5d1611727dc0e33906dd858008dd112d_54746c8a36e6.slice/'
        'intersyntactic-web-driver.service\n',
      );
      expect(release, isNotNull);
    });

    test('null for a cgroup not shaped like a per-release slice', () {
      expect(
        DriverRelease.parse('0::/system.slice/some-other.service\n'),
        isNull,
      );
      expect(DriverRelease.parse(''), isNull);
    });
  });

  group('DriverRelease.parseExpected', () {
    test('reads infra\'s own releaseId(sha, digest) format', () {
      final expected = DriverRelease.parseExpected(
        '7cf5006359c68f657b34ae4fbc845920987585f1-54746c8a36e6',
      );
      expect(expected, isNotNull);
      expect(expected!.sha, '7cf5006359c68f657b34ae4fbc845920987585f1');
      expect(expected.digest, '54746c8a36e6');
      expect(expected.unit, isEmpty);
    });

    test('null for anything not shaped <sha>-<digest>', () {
      expect(DriverRelease.parseExpected('not-a-release-id'), isNull);
      expect(DriverRelease.parseExpected(''), isNull);
    });

    test('matches an equivalent release parsed from a real cgroup, '
        'ignoring unit', () {
      final expected = DriverRelease.parseExpected(
        '7cf5006359c68f657b34ae4fbc845920987585f1-54746c8a36e6',
      )!;
      final real = DriverRelease.parse(
        '0::/system.slice/system-release_'
        '7cf5006359c68f657b34ae4fbc845920987585f1_54746c8a36e6.slice/'
        'intersyntactic-web-driver.service\n',
      )!;
      expect(expected.matches(real), isTrue);
    });
  });

  group('checkDriverRelease, over a real Unix domain socket', () {
    late Directory directory;
    late ServerSocket server;
    late Socket client;
    late UserId me;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'driver_release_test',
      );
      final address = InternetAddress(
        '${directory.path}/socket',
        type: InternetAddressType.unix,
      );
      server = await ServerSocket.bind(address, 0);
      client = await Socket.connect(address, 0);
      final result = await Process.run('id', ['-u']);
      final out = result.stdout;
      me = UserId.parse(
        int.parse((out is String ? out : '').trim()),
      )!;
    });

    tearDown(() async {
      client.destroy();
      await server.close();
      await directory.delete(recursive: true);
    });

    test('allows the expected user through when no release is expected', () async {
      final check = checkDriverRelease(expectedUser: me);
      expect(await check(client), isNull);
    });

    test('refuses a user that is not the expected one', () async {
      final notMe = UserId.parse(me.number == 0 ? 1 : 0)!;
      final check = checkDriverRelease(expectedUser: notMe);
      expect(await check(client), isNotNull);
    });

    test(
      'refuses when a release is expected but this machine can\'t read '
      'one (off Linux, or no per-release slice)',
      () async {
        final check = checkDriverRelease(
          expectedUser: me,
          expected: DriverRelease.parseExpected('${'a' * 40}-${'b' * 12}'),
        );
        if (Platform.isLinux) {
          markTestSkipped(
            'this machine can read a real release; see driverReleaseOf',
          );
          return;
        }
        expect(await check(client), isNotNull);
      },
    );
  });

  group('driverReleaseOf off Linux (this test machine)', () {
    test('is null', () async {
      final directory = await Directory.systemTemp.createTemp(
        'driver_release_test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final address = InternetAddress(
        '${directory.path}/socket',
        type: InternetAddressType.unix,
      );
      final server = await ServerSocket.bind(address, 0);
      final client = await Socket.connect(address, 0);
      addTearDown(() async {
        client.destroy();
        await server.close();
      });
      if (Platform.isLinux) {
        markTestSkipped('driverReleaseOf reads a real release on Linux');
        return;
      }
      expect(await driverReleaseOf(client), isNull);
    });
  });
}
