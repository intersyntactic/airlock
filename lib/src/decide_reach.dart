import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_conversation_reply_vocabulary/is_conversation_reply_vocabulary.dart'
    show ReplyEndpoint;
import 'package:is_effects/is_effects.dart';
import 'package:is_flight_rules/is_flight_rules.dart';
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, PathPrefix, WebPath;

/// Every production grant the airlock service makes, under the rules given
/// to [decide] and the replyEndpoint [noteReplyEndpoint] recorded for the
/// trajectory deciding: files and writes carry nothing off this machine by
/// themselves, so neither needs a rule here. A program is different — a
/// suit on `sharesThisMachinesNetwork` reaches the internet, so which
/// programs may start is itself the rule, checked against
/// `FlightRules.allowsProgram`.
///
/// Held in lib/, not bin/airlock_service.dart, so a test can reach it
/// directly rather than only through the whole service.
///
/// [noteReplyEndpoint] is called once per trajectory, when its own admitted
/// entry is read (`runAirlockService`'s own `onTrajectoryStarted`): [decide]
/// is given only a trajectory id, reach and rules by
/// [DecidesActionsAndWritesToTheLogbook]'s own interface, so the
/// replyEndpoint a `ToOwnReplyEndpoint` grant needs is kept here, by
/// trajectory, rather than threaded through a signature this package does
/// not own.
final class GrantsReaches {
  final _replyEndpointOf = <TrajectoryId, ReplyEndpoint?>{};

  /// [trajectory]'s own replyEndpoint, read from the admitted entry that
  /// started it — where replies to the event that opened it go, or null
  /// when it named none.
  void noteReplyEndpoint(TrajectoryId trajectory, ReplyEndpoint? replyEndpoint) {
    _replyEndpointOf[trajectory] = replyEndpoint;
  }

  Decision decide(
    TrajectoryId trajectory,
    Reach reach,
    FlightRules rules,
  ) => switch (reach) {
    Reads() || Writes() => const Allow.withNoPaths(by: null),
    Starts(:final program) => rules.allowsProgram(program)
        ? const Allow.withNoPaths(by: DecidedBy.rules)
        : Deny('not granted: starts $program', by: DecidedBy.rules),
    MakesWebRequests(:final requests) => grantEachWebRequest(
      rules.whatMayLeaveThisMachine,
      requests,
      replyEndpoint: _replyEndpointOf[trajectory],
    ),
    FetchesFromWeb(:final origin, :final path, :final signIn) =>
      grantFetch(rules.whatMayLeaveThisMachine, origin, path, signIn),
    RepliesToOwnConversation() =>
      grantReply(rules.whatMayLeaveThisMachine, _replyEndpointOf[trajectory]),
    CallsTheModel(:final signIn) => rules.whatMayLeaveThisMachine.allowsModelCall(signIn)
        ? const Allow.withNoPaths(by: DecidedBy.rules)
        : Deny('not granted: model calls as $signIn', by: DecidedBy.rules),
  };
}

/// Every one of [requests] granted together, in order: a [MakesWebRequests]
/// sends them all or none, so the first missing grant denies the whole
/// reach, and the surviving grant collects one path prefix per request for
/// [Allow.grantedPathPrefixes] — never a web request unbounded.
///
/// [replyEndpoint] is the trajectory's own, or null when it has none: it is
/// what makes a [ToOwnReplyEndpoint] grant on some of [requests] matchable
/// at all.
Decision grantEachWebRequest(
  WhatMayLeaveThisMachine rules,
  List<ProposedRequest> requests, {
  required ReplyEndpoint? replyEndpoint,
}) {
  final prefixes = <PathPrefix>[];
  for (final request in requests) {
    switch (rules.webRequestsGrantFor(
      request.origin,
      request.path,
      request.signIn,
      leasedNow: const {},
      pooled: const {},
      replyEndpoint: replyEndpoint,
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

/// Whether [rules] lets a reply go to [replyEndpoint], the trajectory's own:
/// denied outright with no endpoint, since there is nowhere granted to post
/// to; otherwise [Allow.toReplyTo] as whichever sign-in
/// [WhatMayLeaveThisMachine.signInForReply] lets it go as, or denied when
/// none can.
Decision grantReply(WhatMayLeaveThisMachine rules, ReplyEndpoint? replyEndpoint) {
  if (replyEndpoint == null) {
    return const Deny(
      'not granted: no reply endpoint for this trajectory',
      by: DecidedBy.rules,
    );
  }
  final signIn = rules.signInForReply(
    replyEndpoint: replyEndpoint,
    leasedNow: const {},
    pooled: const {},
  );
  if (signIn == null) {
    return Deny('not granted: no sign-in to reply as', by: DecidedBy.rules);
  }
  return Allow.toReplyTo(replyEndpoint, asSignIn: signIn, by: DecidedBy.rules);
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
