import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_flight_rules/is_flight_rules.dart';

/// Every production grant the airlock service makes, under [rules]: files,
/// writes and programs carry nothing off this machine by themselves, so
/// none needs a rule here (`WhatMayLeaveThisMachine`'s own doc comment);
/// only a web request or a model call does.
///
/// Held in lib/, not bin/airlock_service.dart, so a test can reach it
/// directly rather than only through the whole service.
Decision decideReach(
  TrajectoryId trajectory,
  Reach reach,
  WhatMayLeaveThisMachine rules,
) => switch (reach) {
  Reads() || Writes() || Starts() => const Allow.withNoPaths(by: DecidedBy.rules),
  MakesWebRequests(:final requests) => grantEachWebRequest(rules, requests),
  FetchesFromWeb(:final origin, :final path, :final signIn) =>
    grantFetch(rules, origin, path, signIn),
  CallsTheModel(:final signIn) => rules.allowsModelCall(signIn)
      ? const Allow.withNoPaths(by: DecidedBy.rules)
      : Deny('not granted: model calls as $signIn', by: DecidedBy.rules),
};

/// Every one of [requests] granted together, in order: a [MakesWebRequests]
/// sends them all or none, so the first missing grant denies the whole
/// reach, and the surviving grant collects one path prefix per request for
/// [Allow.grantedPathPrefixes] — never a web request unbounded.
///
/// `replyEndpoint` is not yet available here: it is written by the docking
/// station on the admission that starts a trajectory, but exposed only by
/// is_docking_station_api 0.2.0+, which this package does not yet depend
/// on (tasks 62/67, still blocked). So a [ToOwnReplyEndpoint] grant never
/// matches here yet — a real gap, not a guess, until that dependency lands
/// and this reads the trajectory's own recorded endpoint.
Decision grantEachWebRequest(
  WhatMayLeaveThisMachine rules,
  List<ProposedRequest> requests,
) {
  final prefixes = <PathPrefix>[];
  for (final request in requests) {
    switch (rules.webRequestsGrantFor(
      request.origin,
      request.path,
      request.signIn,
      leasedNow: const {},
      pooled: const {},
      replyEndpoint: null,
    )) {
      case null:
        return Deny(
          'not granted: ${request.origin} as ${request.signIn ?? 'no sign-in'}',
          by: DecidedBy.rules,
        );
      case (grant: _, grantedPathPrefix: final prefix):
        prefixes.add(prefix);
    }
  }
  return Allow(by: DecidedBy.rules, grantedPathPrefixes: prefixes);
}

/// Whether [rules] grants a fetch to [path] on [origin] as [signIn].
/// Nothing is relied on beyond the rules yet: `leasedNow` and `pooled` are
/// both empty until loop_launcher's lease-tracking entries exist (task 49).
Decision grantFetch(
  WhatMayLeaveThisMachine rules,
  Origin origin,
  WebPath path,
  SignIn? signIn,
) => switch (rules.fetchGrantFor(
  origin,
  path,
  signIn,
  leasedNow: const {},
  pooled: const {},
)) {
  null => Deny(
    'not granted: $origin as ${signIn ?? 'no sign-in'}',
    by: DecidedBy.rules,
  ),
  (grant: _, grantedPathPrefix: final prefix) => Allow(
    by: DecidedBy.rules,
    grantedPathPrefixes: [prefix],
  ),
};
