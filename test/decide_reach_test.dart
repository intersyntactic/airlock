// `decideReach` (lib/src/decide_reach.dart) is what bin/airlock_service.dart
// actually decides with in production — these tests exercise it directly,
// not a fake that grants everything under `/` (airlock-api-b3's finding on
// PR #23).
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:test/test.dart';

final _trajectory = TrajectoryId.of(Uint8List.fromList([1, 2, 3]));
final _site = Origin.parse('https://api.example')!;
final _otherSite = Origin.parse('https://other.example')!;
final _signIn = SignIn.parse('cam-teams')!;

/// [GrantsReaches.decide], for a one-off call that doesn't need its own
/// instance: [trajectory]'s own replyEndpoint, when given, is recorded
/// before deciding, exactly as `runAirlockService`'s `onTrajectoryStarted`
/// would.
Decision decideReach(
  TrajectoryId trajectory,
  Reach reach,
  WhatMayLeaveThisMachine rules, {
  AddressPrefix? replyEndpoint,
}) {
  final grants = GrantsReaches();
  if (replyEndpoint != null) grants.noteReplyEndpoint(trajectory, replyEndpoint);
  return grants.decide(trajectory, reach, rules);
}

WhatMayLeaveThisMachine _rules({
  Iterable<GrantToFetch> fetchesMayReach = const [],
  Iterable<GrantToMakeWebRequests> webRequestsMayReach = const [],
}) => WhatMayLeaveThisMachine(
  modelSignInsCallsMayGoOutAs: const [],
  fetchesMayReach: fetchesMayReach,
  webRequestsMayReach: webRequestsMayReach,
  programsNetwork: ProgramsNetwork.noNetworkOfTheirOwn,
);

GrantToMakeWebRequests _grantRequestsTo(Origin origin, String prefix) =>
    GrantToMakeWebRequests(
      ToAddressesUnder(AddressPrefix.of(origin, PathPrefix.parse(prefix)!)),
      GoesAsSignIn(_signIn),
    );

ProposedRequest _requestTo(Origin origin, String path) =>
    ProposedRequest(origin, path: WebPath.parse(path)!, signIn: _signIn);

void main() {
  group('decideReach: MakesWebRequests', () {
    test(
      'grants one path prefix per request, under the rule\'s own prefix, '
      'not the whole site',
      () {
        final rules = _rules(
          webRequestsMayReach: [_grantRequestsTo(_site, '/v1/things/')],
        );
        final decision = decideReach(
          _trajectory,
          MakesWebRequests([
            _requestTo(_site, '/v1/things/'),
            _requestTo(_site, '/v1/things/abc'),
          ]),
          rules,
        );
        expect(decision, isA<Allow>());
        final allow = decision as Allow;
        expect(allow.grantedPathPrefixes, hasLength(2));
        expect(
          allow.grantedPathPrefixes,
          everyElement(PathPrefix.parse('/v1/things/')),
        );
      },
    );

    test(
      'grants each request its own rule\'s prefix, in order — not every '
      "request the first request's prefix",
      () {
        final rules = _rules(
          webRequestsMayReach: [
            _grantRequestsTo(_site, '/v1/things/'),
            _grantRequestsTo(_site, '/v2/other/'),
          ],
        );
        final decision = decideReach(
          _trajectory,
          MakesWebRequests([
            _requestTo(_site, '/v1/things/abc'),
            _requestTo(_site, '/v2/other/xyz'),
          ]),
          rules,
        );
        expect(decision, isA<Allow>());
        expect((decision as Allow).grantedPathPrefixes, [
          PathPrefix.parse('/v1/things/'),
          PathPrefix.parse('/v2/other/'),
        ]);
      },
    );

    test('denies the whole reach when any one request is ungranted', () {
      final rules = _rules(
        webRequestsMayReach: [_grantRequestsTo(_site, '/v1/things/')],
      );
      final decision = decideReach(
        _trajectory,
        MakesWebRequests([
          _requestTo(_site, '/v1/things/'),
          _requestTo(_otherSite, '/v1/things/'),
        ]),
        rules,
      );
      expect(decision, isA<Deny>());
      expect((decision as Deny).why, contains('$_otherSite'));
    });

    test('denies with no grants at all', () {
      final decision = decideReach(
        _trajectory,
        MakesWebRequests([_requestTo(_site, '/v1/things/')]),
        _rules(),
      );
      expect(decision, isA<Deny>());
    });
  });

  group('GrantsReaches: ToOwnReplyEndpoint', () {
    final rules = _rules(
      webRequestsMayReach: [
        GrantToMakeWebRequests(
          ToOwnReplyEndpoint.of([_site])!,
          GoesAsSignIn(_signIn),
        ),
      ],
    );

    test(
      'grants a reply once the trajectory\'s own replyEndpoint is noted '
      '(infra task 215 — the replyEndpoint:null gap PR #27 left open)',
      () {
        final grants = GrantsReaches();
        grants.noteReplyEndpoint(
          _trajectory,
          AddressPrefix.of(_site, PathPrefix.parse('/reply/')!),
        );
        final decision = grants.decide(
          _trajectory,
          MakesWebRequests([_requestTo(_site, '/reply/abc')]),
          rules,
        );
        expect(decision, isA<Allow>());
        expect((decision as Allow).grantedPathPrefixes, [
          PathPrefix.parse('/reply/'),
        ]);
      },
    );

    test('denies a reply when no replyEndpoint was ever noted', () {
      final decision = GrantsReaches().decide(
        _trajectory,
        MakesWebRequests([_requestTo(_site, '/reply/abc')]),
        rules,
      );
      expect(decision, isA<Deny>());
    });

    test(
      'denies a reply to a path outside the noted replyEndpoint\'s prefix',
      () {
        final grants = GrantsReaches();
        grants.noteReplyEndpoint(
          _trajectory,
          AddressPrefix.of(_site, PathPrefix.parse('/reply/')!),
        );
        final decision = grants.decide(
          _trajectory,
          MakesWebRequests([_requestTo(_site, '/elsewhere/abc')]),
          rules,
        );
        expect(decision, isA<Deny>());
      },
    );
  });

  group('decideReach: FetchesFromWeb', () {
    test('grants the rule\'s own prefix, not the whole site', () {
      final rules = _rules(
        fetchesMayReach: [
          GrantToFetch(
            FromAddressesUnder(AddressPrefix.of(_site, PathPrefix.parse('/docs/')!)),
            GoesAsSignIn(_signIn),
          ),
        ],
      );
      final decision = decideReach(
        _trajectory,
        FetchesFromWeb(
          WebFetch(
            _site,
            path: WebPath.parse('/docs/page')!,
            keep: BodyToKeep.none,
            signIn: _signIn,
          ),
        ),
        rules,
      );
      expect(decision, isA<Allow>());
      expect(
        (decision as Allow).grantedPathPrefixes,
        [PathPrefix.parse('/docs/')],
      );
    });

    test('denies a fetch under no matching grant', () {
      final decision = decideReach(
        _trajectory,
        FetchesFromWeb(
          WebFetch(_otherSite, keep: BodyToKeep.none, signIn: _signIn),
        ),
        _rules(),
      );
      expect(decision, isA<Deny>());
    });

    test(
      'a FromPathsMatching grant passes on the matched read\'s own '
      'prefix, not the whole site (airlock_api#45)',
      () {
        final pattern = PathPattern.parse(
          '/v1.0/drives/D/items/F:/{name}:/content',
        )!;
        final rules = _rules(
          fetchesMayReach: [
            GrantToFetch(
              FromPathsMatching.of(_site, [pattern])!,
              GoesAsSignIn(_signIn),
            ),
          ],
        );

        final matched = decideReach(
          _trajectory,
          FetchesFromWeb(
            WebFetch(
              _site,
              path: WebPath.parse(
                '/v1.0/drives/D/items/F:/a.docx:/content',
              )!,
              keep: BodyToKeep.none,
              signIn: _signIn,
            ),
          ),
          rules,
        );
        expect(matched, isA<Allow>());
        expect((matched as Allow).grantedPathPrefixes, [
          PathPrefix.parse('/v1.0/drives/D/items/F:/a.docx:/'),
        ]);

        final unmatched = decideReach(
          _trajectory,
          FetchesFromWeb(
            WebFetch(
              _site,
              path: WebPath.parse('/v1.0/drives/D/items/OTHER/content')!,
              keep: BodyToKeep.none,
              signIn: _signIn,
            ),
          ),
          rules,
        );
        expect(unmatched, isA<Deny>());
      },
    );
  });

  group('decideReach: other reaches', () {
    test('Reads/Writes/Starts need no grant at all', () {
      final rules = _rules();
      expect(
        decideReach(_trajectory, Reads(RelativePath.root), rules),
        isA<Allow>(),
      );
      expect(
        decideReach(
          _trajectory,
          Writes(FileText(RelativePath.root, '')),
          rules,
        ),
        isA<Allow>(),
      );
      expect(
        decideReach(
          _trajectory,
          Starts(ProgramName.parse('dart')!, const Args([])),
          rules,
        ),
        isA<Allow>(),
      );
    });

    test('CallsTheModel is granted only for a sign-in the rules name', () {
      final rules = WhatMayLeaveThisMachine(
        modelSignInsCallsMayGoOutAs: [ModelSignInName.parse('cam-teams')!],
        fetchesMayReach: const [],
        webRequestsMayReach: const [],
        programsNetwork: ProgramsNetwork.noNetworkOfTheirOwn,
      );
      expect(
        decideReach(
          _trajectory,
          CallsTheModel(
            ModelCall(
              signIn: ModelSignInName.parse('cam-teams')!,
              model: ModelName.parse('claude-opus-5-5')!,
              request: EntryId.of(Uint8List.fromList([1])),
            ),
          ),
          rules,
        ),
        isA<Allow>(),
      );
      expect(
        decideReach(
          _trajectory,
          CallsTheModel(
            ModelCall(
              signIn: ModelSignInName.parse('nick-claude-team')!,
              model: ModelName.parse('claude-opus-5-5')!,
              request: EntryId.of(Uint8List.fromList([1])),
            ),
          ),
          rules,
        ),
        isA<Deny>(),
      );
    });
  });
}
