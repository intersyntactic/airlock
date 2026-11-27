// `decideReach` (lib/src/decide_reach.dart) is what bin/airlock_service.dart
// actually decides with in production — these tests exercise it directly,
// not a fake that grants everything under `/` (airlock-api-b3's finding on
// PR #23).
import 'dart:typed_data';

import 'package:is_airlock/is_airlock.dart';
import 'package:is_conversation_reply_vocabulary/is_conversation_reply_vocabulary.dart'
    show RepliesUnderWebAddress, ReplyContent, ReplyEndpoint, ReplyText;
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show AddressPrefix, Origin, PathPrefix, WebPath;
import 'package:test/test.dart';

final _trajectory = TrajectoryId.of(Uint8List.fromList([1, 2, 3]));
final _site = Origin.parse('https://api.example')!;
final _otherSite = Origin.parse('https://other.example')!;
final _signIn = SignIn.parse('cam-teams')!;
final _startingSignIn = ModelSignInName.parse('starting-sign-in')!;
final _startingModel = ModelAndSignIn(
  signIn: _startingSignIn,
  model: ModelName.parse('claude-opus-5-5')!,
);

/// [GrantsReaches.decide], for a one-off call that doesn't need its own
/// instance: [trajectory]'s own replyEndpoint, when given, is recorded
/// before deciding, exactly as `runAirlockService`'s `onTrajectoryStarted`
/// would.
Decision decideReach(
  TrajectoryId trajectory,
  Reach reach,
  FlightRules rules, {
  ReplyEndpoint? replyEndpoint,
}) {
  final grants = GrantsReaches();
  if (replyEndpoint != null) grants.noteReplyEndpoint(trajectory, replyEndpoint);
  return grants.decide(trajectory, reach, rules);
}

FlightRules _rules({
  Iterable<GrantToFetch> fetchesMayReach = const [],
  Iterable<GrantToMakeWebRequests> webRequestsMayReach = const [],
  Iterable<ProgramName> programsItMayRun = const [],
}) => FlightRules.of(
  whatMayLeaveThisMachine: WhatMayLeaveThisMachine(
    modelSignInsCallsMayGoOutAs: [_startingSignIn],
    fetchesMayReach: fetchesMayReach,
    webRequestsMayReach: webRequestsMayReach,
    programsNetwork: ProgramsNetwork.noNetworkOfTheirOwn,
  ),
  startingModel: _startingModel,
  programsItMayRun: programsItMayRun,
  programsItNeeds: const [],
  givenTools: const [],
)!;

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
          RepliesUnderWebAddress(
            AddressPrefix.of(_site, PathPrefix.parse('/reply/')!),
          ),
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
          RepliesUnderWebAddress(
            AddressPrefix.of(_site, PathPrefix.parse('/reply/')!),
          ),
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

  group('decideReach: RepliesToOwnConversation', () {
    final content = ReplyContent(text: ReplyText.parse('hi')!);
    final endpoint = RepliesUnderWebAddress(
      AddressPrefix.of(_site, PathPrefix.parse('/reply/')!),
    );
    final rules = _rules(
      webRequestsMayReach: [
        GrantToMakeWebRequests(
          ToOwnReplyEndpoint.of([_site])!,
          GoesAsSignIn(_signIn),
        ),
      ],
    );

    test(
      'allows the reply, granted the trajectory\'s own endpoint, once it is '
      'noted',
      () {
        final grants = GrantsReaches();
        grants.noteReplyEndpoint(_trajectory, endpoint);
        final decision = grants.decide(
          _trajectory,
          RepliesToOwnConversation(content),
          rules,
        );
        expect(decision, isA<Allow>());
        final allow = decision as Allow;
        expect(allow.grantedReply, (to: endpoint, asSignIn: _signIn));
        expect(allow.grantedPathPrefixes, isEmpty);
      },
    );

    test('denies a reply when no replyEndpoint was ever noted', () {
      final decision = decideReach(
        _trajectory,
        RepliesToOwnConversation(content),
        rules,
      );
      expect(decision, isA<Deny>());
    });

    test('denies a reply when no rule grants this endpoint\'s origin', () {
      final decision = decideReach(
        _trajectory,
        RepliesToOwnConversation(content),
        _rules(),
        replyEndpoint: endpoint,
      );
      expect(decision, isA<Deny>());
    });
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
    test(
      'Reads/Writes need no grant at all, and are honest that no rule '
      'governs them (task 78: Allow.by is null here, never DecidedBy.rules)',
      () {
        final rules = _rules();
        final reads = decideReach(_trajectory, Reads(RelativePath.root), rules);
        expect(reads, isA<Allow>());
        expect((reads as Allow).by, isNull);

        final writes = decideReach(
          _trajectory,
          Writes(FileText(RelativePath.root, '')),
          rules,
        );
        expect(writes, isA<Allow>());
        expect((writes as Allow).by, isNull);
      },
    );

    test(
      'Starts is granted for a program the rules list in programsItMayRun',
      () {
        final rules = _rules(
          programsItMayRun: [ProgramName.parse('teams-reply-drawing')!],
        );
        expect(
          decideReach(
            _trajectory,
            Starts(ProgramName.parse('teams-reply-drawing')!, const Args([])),
            rules,
          ),
          isA<Allow>(),
        );
      },
    );

    test(
      'Starts is denied, naming the program, for an installed program not '
      'in programsItMayRun',
      () {
        final rules = _rules(
          programsItMayRun: [ProgramName.parse('teams-reply-drawing')!],
        );
        final decision = decideReach(
          _trajectory,
          Starts(ProgramName.parse('dart')!, const Args([])),
          rules,
        );
        expect(decision, isA<Deny>());
        expect((decision as Deny).why, contains('dart'));
      },
    );

    test('CallsTheModel is granted only for a sign-in the rules name', () {
      final rules = FlightRules.of(
        whatMayLeaveThisMachine: WhatMayLeaveThisMachine(
          modelSignInsCallsMayGoOutAs: [ModelSignInName.parse('cam-teams')!],
          fetchesMayReach: const [],
          webRequestsMayReach: const [],
          programsNetwork: ProgramsNetwork.noNetworkOfTheirOwn,
        ),
        startingModel: ModelAndSignIn(
          signIn: ModelSignInName.parse('cam-teams')!,
          model: ModelName.parse('claude-opus-5-5')!,
        ),
        programsItMayRun: const [],
        programsItNeeds: const [],
        givenTools: const [],
      )!;
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
