/// Which release a connected driver (the web driver, the model driver) is
/// actually running, read from the kernel rather than trusted from the
/// driver's own say-so, and wired through [CheckDriver] — the airlock's
/// own typedef, matching `is_web_request_driver`'s — run on every
/// connection before a request is sent.
///
/// From `enspyrco/infra`#408's per-release systemd slice and
/// `scripts/lib/release_deploy.dart`'s own naming:
/// `system-release_<sha>_<digest>.slice/intersyntactic-<unit>.service`,
/// where `digest` is a SHA-256 over the release's *config* (its systemd
/// unit, env and secrets) — not a hash of the code — so the same commit
/// can carry a different digest if deployed under a changed unit, user or
/// secret. Checking the sha alone would accept a reviewed binary started
/// under an unreviewed unit; this checks both.
///
/// The user check is `is_unix_socket_user_check`'s own (Nick's brief,
/// `verified-wall` `docs/PEER-UID-BRIEF.md`: one package for every peer-uid
/// read instead of each caller's own copy) — never a hardcoded or
/// socket-file-derived uid, which would trust whoever created the file
/// first rather than something independent of the driver it checks.
///
/// Only the release half is Linux-only: `SO_PEERPIDFD` and `/proc` don't
/// exist on the macOS boxes this also runs on in development, so the
/// release check is a no-op off Linux rather than a failure. The user
/// check runs everywhere `is_unix_socket_user_check` reads a kernel for
/// (Linux's `SO_PEERCRED`, macOS's `LOCAL_PEERCRED`).
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';

// [UserId] is part of [checkDriverRelease]'s own signature, so a caller
// building one needs it without a second direct dependency on this
// package.
export 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart'
    show UserId;

const _solSocket = 1;
// The asm-generic value, correct for the x86-64 and arm64 boxes this runs
// on; wrong on alpha, mips, parisc and sparc, which define their own.
const _soPeerPidfd = 77;

final int Function(int) _libcClose = ffi.DynamicLibrary.process()
    .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>('close');

/// The commit and config identity of a driver process. [sha] names which
/// code is running; [digest] names the systemd unit, env and secrets it's
/// running under — the release's config identity (see the library doc).
/// [unit] is the systemd service name, or empty on a release built by
/// [parseExpected], which names no unit at all.
final class DriverRelease {
  const DriverRelease._(this.sha, this.digest, this.unit);

  final String sha;
  final String digest;
  final String unit;

  static final _shape = RegExp(
    r'^0::/system\.slice/system-release_([0-9a-f]{40})_([0-9a-f]{12})\.slice/'
    r'intersyntactic-([a-z0-9-]+)\.service$',
  );

  /// Parses a `/proc/<pid>/cgroup` file's contents (the unified, `0::`,
  /// hierarchy line) into the release it names, or null if no line is
  /// shaped like a per-release slice at all — a process not started this
  /// way, not this file's own format changing underfoot.
  static DriverRelease? parse(String cgroupFileContents) {
    for (final line in cgroupFileContents.split('\n')) {
      final match = _shape.firstMatch(line.trim());
      if (match != null) {
        return DriverRelease._(
          match.group(1)!,
          match.group(2)!,
          match.group(3)!,
        );
      }
    }
    return null;
  }

  static final _expectedShape = RegExp(r'^([0-9a-f]{40})-([0-9a-f]{12})$');

  /// Parses infra's own `releaseId(sha, digest)` format (`sha` followed by
  /// the first 12 hex digits of `digest`, joined with a dash;
  /// `enspyrco/infra` `scripts/lib/release_deploy.dart`):
  /// what an env var names as the one release a driver is expected to be
  /// running. Null if [releaseId] isn't shaped that way.
  static DriverRelease? parseExpected(String releaseId) {
    final match = _expectedShape.firstMatch(releaseId);
    return match == null
        ? null
        : DriverRelease._(match.group(1)!, match.group(2)!, '');
  }

  /// Whether [other] names the same sha and digest as this one. Never
  /// compares [unit]: a release built by [parseExpected] carries no unit
  /// to compare.
  bool matches(DriverRelease other) =>
      sha == other.sha && digest == other.digest;

  @override
  String toString() => unit.isEmpty ? '$sha-$digest' : '$unit@$sha-$digest';
}

/// The release of whoever is on the other end of [socket], read from its
/// cgroup via `SO_PEERPIDFD`. Null off Linux, or where the kernel calls
/// this needs aren't available (no `SO_PEERPIDFD`, an unreadable `/proc`
/// entry, or a peer process whose cgroup isn't a per-release slice).
Future<DriverRelease?> driverReleaseOf(Socket socket) async {
  if (!Platform.isLinux) return null;
  final int pidfd;
  try {
    final bytes = socket.getRawOption(
      RawSocketOption(_solSocket, _soPeerPidfd, Uint8List(4)),
    );
    pidfd = ByteData.sublistView(bytes).getInt32(0, Endian.host);
  } on SocketException {
    return null;
  }
  try {
    final pid = await _pidOfPidfd(pidfd);
    if (pid == null) return null;
    final cgroup = await File('/proc/$pid/cgroup').readAsString();
    final release = DriverRelease.parse(cgroup);
    // TOCTOU guard: the pid could have exited and been reaped between the
    // cgroup read above and here. The kernel blanks a pidfd's own
    // `Pid:` fdinfo line to -1 once its task is gone (pidfd_show_fdinfo),
    // so re-reading it and requiring the same positive pid catches that.
    return await _pidOfPidfd(pidfd) == pid ? release : null;
  } on FileSystemException {
    return null;
  } finally {
    _libcClose(pidfd);
  }
}

Future<int?> _pidOfPidfd(int pidfd) async {
  for (final line in await File('/proc/self/fdinfo/$pidfd').readAsLines()) {
    if (line.startsWith('Pid:')) return int.tryParse(line.substring(4).trim());
  }
  return null;
}

/// [value] as a [UserId]: a numeric uid as itself, a name resolved the
/// same way every driver's own `bin/` resolves its `*_CALLER` (`id -u`).
/// Null for anything `id` or [UserId.parse] refuses, or a value shaped
/// like a command-line option — starting with `-` — which `id` could
/// otherwise read as a flag instead of a name, same guard as
/// `is_logbook`'s own `_uidOfUser`.
UserId? userNamedBy(String value) {
  if (value.startsWith('-')) return null;
  final uid = int.tryParse(value) ?? _resolveUid(value);
  return uid == null ? null : UserId.parse(uid);
}

int? _resolveUid(String user) {
  final result = Process.runSync('id', ['-u', user]);
  final out = result.stdout;
  return result.exitCode == 0 && out is String ? int.tryParse(out.trim()) : null;
}

/// Looks at the driver on the other end of a connected socket, such as
/// which release the kernel says it is, before any call is written to it.
/// Returns why to refuse it, or null to go on. Structurally the same as
/// is_web_request_driver's own matching typedef — never that type by name,
/// since this package holds no dependency on it, but the two compose
/// wherever a driver's socket needs checking.
typedef CheckDriver = Future<String?> Function(Socket driver);

/// Builds a [CheckDriver] that refuses a driver connection unless
/// `is_unix_socket_user_check` says it's running as [expectedUser] — an
/// unreadable peer user is refused, never skipped — and, when [expected]
/// is given, that its release's sha and digest match. A driver this can't
/// read any release for at all (a peer whose cgroup isn't a per-release
/// slice, or off Linux, where there's nothing to read) is refused whenever
/// [expected] is given, and passed through untouched otherwise: release
/// matching is opt-in per driver, so it's a no-op until something actually
/// sets an expectation.
CheckDriver checkDriverRelease({
  required UserId expectedUser,
  DriverRelease? expected,
}) {
  final userCheck = SocketUserCheck.only(expectedUser);
  return (Socket driver) async {
    if (!userCheck.allows(driver)) {
      return 'not connected as the driver\'s own user $expectedUser';
    }
    if (expected == null) return null;
    final release = await driverReleaseOf(driver);
    if (release == null) {
      return 'no readable release identity, and $expected was expected';
    }
    if (!expected.matches(release)) {
      return 'release $release does not match expected $expected';
    }
    return null;
  };
}
