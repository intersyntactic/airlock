/// One agent's own trajectory, and what decides and carries out its
/// actions: moved here from `is_airlock_api` (0.21.0, "the contract holds
/// types and their JSON only"), since deciding and carrying an action out
/// is this package's job, never the contract's.
library;

import 'dart:async';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_model_vocabulary/is_model_vocabulary.dart' show ModelReply;
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;

/// Decides each action on a trajectory, and writes its decision to the
/// logbook.
///
/// What intersyntactic's airlock implements (`Airlock`). It guards the
/// drivers it is given, not the mission: an agent that joins a mission
/// with its own drivers is decided, or not, by its own.
abstract interface class DecidesActionsAndWritesToTheLogbook<R, P> {
  /// Whether a driver may carry out an action of [trajectory]'s that would
  /// do [reach], under [rules].
  ///
  /// Given the reach, not the action, so the decision is about exactly what
  /// the logbook keeps: for a [MakesWebRequests], every request it sends, each to be
  /// granted by its origin, sign-in and path together. Given the trajectory,
  /// so the airlock can read what holds for it now from its chain, such as
  /// the bot leased to it, at the moment of deciding; the decision names
  /// each entry it read in [Decision.reliedOn].
  Future<Decision> decide(TrajectoryId trajectory, Reach reach, R rules);

  /// Keeps [decision] in the logbook. An action's driver is reached only
  /// once its decision is kept; an error thrown here ends the call.
  Future<void> writeDecision(AirlockDecisionOnAction<P> decision);

  /// Keeps in the logbook what the action [decision] was about came to:
  /// [result], what it ran to or why it was refused, which [resultAsJson]
  /// holds as its program's codec writes it. The action's continuation sees
  /// [result] only once it is kept; an error thrown here ends the call.
  Future<void> writeResult(
    AirlockDecisionOnAction<P> decision,
    Outcome<Object?> result, {
    required Object? resultAsJson,
  });

  /// The kind and body of [entry], when it belongs to [trajectory]: the
  /// body as text, after its `<kind>\n<previous>\n` header. Or [NothingRan]
  /// with why not. Whoever reads it checks the kind it expects, since a
  /// loop may write a body of any shape under its own kinds.
  Future<Outcome<({String kind, String body})>> entryOn(
    TrajectoryId trajectory,
    EntryId entry,
  );
}

/// One agent's own trajectory: the line its actions are proposed on, with
/// rules [R] that say what it may do, and places [P] that say where in a
/// turn each entry happened.
///
/// Its drivers are those it was given, acting for the path, each wherever
/// it runs. They are reached only by an action proposed at its crux, so
/// every such action passes its airlock.
///
/// [webAddressReplies] and [pinnedBodyReplies] are the modules' writers
/// that draw a reply's web requests, for each kind of reply endpoint; a
/// reply to an endpoint this trajectory has no writer for runs nothing.
final class Trajectory<R, P> {
  Trajectory({
    required this.id,
    required Iterable<CarriesOutActions> drivers,
    required this._airlock,
    required this.rules,
    required this.suit,
    this._webAddressReplies,
    this._pinnedBodyReplies,
  }) : _drivers = List.unmodifiable(drivers);

  final WritesReplyRequests<RepliesUnderWebAddress>? _webAddressReplies;
  final PinnedBodyReplyWriters? _pinnedBodyReplies;

  /// Names this trajectory in every entry written for it.
  final TrajectoryId id;
  final R rules;

  /// The OS user this path's programs run as: the airlock service gives the
  /// path a program driver that runs as it. One per path, kept for the
  /// path's life.
  final Suit suit;

  final DecidesActionsAndWritesToTheLogbook<R, P> _airlock;
  final List<CarriesOutActions> _drivers;
  final _decisions = StreamController<AirlockDecisionOnAction<P>>.broadcast(
    sync: true,
  );
  final _results =
      StreamController<
        ({AirlockDecisionOnAction<P> decision, Outcome<Object?> result})
      >.broadcast(sync: true);
  final _underway = StreamController<Underway<P>>.broadcast(sync: true);
  bool _stopped = false;

  /// Refuses every action on this trajectory whose driver has not yet been
  /// reached. An action whose driver has been reached is not interrupted.
  /// Never undone.
  void stop() => _stopped = true;

  bool get stopped => _stopped;

  /// Each decision once the logbook has kept it.
  Stream<AirlockDecisionOnAction<P>> get decisions => _decisions.stream;

  /// Each action's result, or why it was refused, once the logbook has kept
  /// it, with the decision it follows.
  Stream<({AirlockDecisionOnAction<P> decision, Outcome<Object?> result})>
  get results => _results.stream;

  /// What drivers report while actions are underway: for a live view, and
  /// never written to the logbook.
  Stream<Underway<P>> get underway => _underway.stream;

  D? _driver<D extends CarriesOutActions>() =>
      _drivers.whereType<D>().firstOrNull;

  Future<Outcome<O>> _consider<I, O>(
    Program<I, O> program,
    I input,
    P place, {
    required EntryId proposed,
  }) async {
    const stoppedByPerson = Deny('stopped', by: DecidedBy.person);
    final reach = program.reachOf(input);
    var decision = stopped
        ? stoppedByPerson
        : await _airlock.decide(id, reach, rules);
    // A stop that came while the airlock decided still wins.
    if (stopped) decision = stoppedByPerson;
    final decided = AirlockDecisionOnAction(
      id,
      place,
      reach,
      decision,
      proposed: proposed,
    );
    await _airlock.writeDecision(decided);
    _decisions.add(decided);
    final Outcome<O> result;
    try {
      result = switch (decision) {
        Deny(:final why) => NothingRan(why),
        final Allow allowed =>
          await program.carriedOutBy(
                _ProgramsFor(
                  this,
                  allowed,
                  (progress) =>
                      _underway.add(Underway(id, place, reach, progress)),
                ),
                input,
              ) ??
              NothingRan('this machine cannot run ${program.name}'),
      };
    } catch (thrown) {
      // A driver that throws may have reached the world first, so its
      // result says what it did is unknown, and the throw still ends the
      // call.
      await _written(
        decided,
        StoppedPartway<O>(why: 'the driver threw: $thrown', done: null),
        program,
      );
      rethrow;
    }
    await _written(decided, result, program);
    return result;
  }

  Future<void> _written<I, O>(
    AirlockDecisionOnAction<P> decided,
    Outcome<O> result,
    Program<I, O> program,
  ) async {
    await _airlock.writeResult(
      decided,
      result,
      resultAsJson: program.outcomeToJson(result),
    );
    _results.add((decision: decided, result: result));
  }

  /// [proposal], the logbook entry [proposed] on this path's chain,
  /// considered at [place]: decided and written to the logbook, and carried
  /// out by a driver if it is allowed. Its decision and its result both
  /// name [proposed]. The one way an action reaches this trajectory's
  /// drivers.
  Future<void> consider(
    ActionProposedByAgentLoop proposal,
    P place, {
    required EntryId proposed,
  }) => proposal.open(
    <I, O>(program, input) =>
        _consider(program, input, place, proposed: proposed),
  );
}

/// What a driver reported, [progress], while the action doing [reach] was
/// underway at [place] on the trajectory named [trajectoryId].
final class Underway<P> {
  const Underway(this.trajectoryId, this.place, this.reach, this.progress);

  final TrajectoryId trajectoryId;
  final P place;
  final Reach reach;
  final Progress progress;
}

/// [CarriesOutEachProgram] for one decided, allowed action on [_trajectory]:
/// built fresh per [Trajectory._consider] call, since the contract's
/// interface carries none of [_allowed] or [_report] itself.
final class _ProgramsFor implements CarriesOutEachProgram {
  const _ProgramsFor(this._trajectory, this._allowed, this._report);

  final Trajectory<Object?, Object?> _trajectory;
  final Allow _allowed;
  final void Function(Progress progress) _report;

  @override
  Future<Outcome<ReadResult>>? readFile(RelativePath path) =>
      _trajectory._driver<ReadsAndWritesFiles>()?.read(path);

  @override
  Future<Outcome<BytesReadResult>>? readFileBytes(RelativePath path) =>
      _trajectory._driver<ReadsAndWritesFiles>()?.readBytes(path);

  @override
  Future<Outcome<Wrote>>? writeFile(FileText file) =>
      _trajectory._driver<ReadsAndWritesFiles>()?.write(file);

  @override
  Future<Outcome<ExecResult>>? runExecutable(ProgramName program, Args args) =>
      _trajectory._driver<RunsPrograms>()?.runProgram(
        program,
        args,
        report: _report,
      );

  @override
  Future<Outcome<List<WebResponse>>>? makeWebRequests(
    List<ProposedRequest> requests,
  ) => switch (_trajectory._driver<CarriesOutWebRequests>()) {
    null => null,
    final web => switch (_granted(requests, _allowed)) {
      NothingRan(:final why) ||
      StoppedPartway(:final why) => Future.value(NothingRan(why)),
      Ran(output: final granted) => _send(web, granted),
    },
  };

  @override
  Future<Outcome<WebResponse>>? fetchFromWeb(WebFetch fetch) =>
      switch (_trajectory._driver<CarriesOutWebRequests>()) {
        null => null,
        final web => switch (_granted([
          ProposedRequest(
            fetch.origin,
            path: fetch.path,
            signIn: fetch.signIn,
            keep: fetch.keep,
          ),
        ], _allowed)) {
          NothingRan(:final why) ||
          StoppedPartway(:final why) => Future.value(NothingRan(why)),
          Ran(:final output) => web.carryOutWebRequest(output.single),
        },
      };

  @override
  Future<Outcome<ModelReply>>? askTheModel(ModelCall call) =>
      switch (_trajectory._driver<AsksTheModel>()) {
        null => null,
        final driver => _ask(driver, _trajectory, call, _report),
      };

  @override
  Future<Outcome<List<PostedMessage>>>? replyToOwnConversation(
    ReplyContent content,
  ) => switch ((
    _allowed.grantedReply,
    _trajectory._driver<CarriesOutWebRequests>(),
  )) {
    (null, _) => Future.value(const NothingRan('allowed with no reply granted')),
    (_, null) => null,
    ((to: final RepliesUnderWebAddress to, :final asSignIn), final web?) =>
      switch (_trajectory._webAddressReplies) {
        null => null,
        final writer => _postReply(
          to,
          asSignIn,
          writer.draw(to, _trajectory.id, content),
          web,
          writer.posted,
          (id) => PostedUnderWebAddress.answering(to, id),
        ),
      },
    ((to: final RepliesWithPinnedBodyFields to, :final asSignIn), final web?) =>
      switch (_trajectory._pinnedBodyReplies?.writerFor(to)) {
        null => null,
        final writer => _postReply(
          to,
          asSignIn,
          writer.draw(to, _trajectory.id, content),
          web,
          writer.posted,
          (id) => PostedWithPinnedBodyFields.answering(to, id),
        ),
      },
  };
}

/// [writers], each claiming the addresses it writes replies to, so the
/// airlock can pick the one writer for a [RepliesWithPinnedBodyFields]
/// endpoint by its origin and path — several services can share this
/// endpoint kind (Slack's and WhatsApp's both pin fields in the body,
/// never the address).
final class PinnedBodyReplyWriters {
  const PinnedBodyReplyWriters._(this._byAddress);

  final Map<({Origin origin, WebPath path}), WritesPinnedBodyReplyRequests>
  _byAddress;

  /// [writers] indexed by address; null when two name the same one, since
  /// the airlock then has no way to pick between them.
  static PinnedBodyReplyWriters? of(
    Iterable<WritesPinnedBodyReplyRequests> writers,
  ) {
    final byAddress = <({Origin origin, WebPath path}), WritesPinnedBodyReplyRequests>{};
    for (final writer in writers) {
      for (final address in writer.addresses) {
        if (byAddress.containsKey(address)) return null;
        byAddress[address] = writer;
      }
    }
    return PinnedBodyReplyWriters._(byAddress);
  }

  /// The writer for [to], when one claims its address; null otherwise.
  WritesPinnedBodyReplyRequests? writerFor(RepliesWithPinnedBodyFields to) =>
      _byAddress[(origin: to.origin, path: to.path)];
}

/// Asks [driver] the model [call] names, through [trajectory]'s own chain:
/// reads the [ModelRequestFromPieces] and each of its pieces, joins each
/// text, and hands the driver exactly those texts. Any piece missing, on
/// another chain, or not joining to its hash refuses the call before the
/// driver is reached.
Future<Outcome<ModelReply>> _ask(
  AsksTheModel driver,
  Trajectory<Object?, Object?> trajectory,
  ModelCall call,
  void Function(Progress progress) report,
) async {
  final ModelRequestFromPieces request;
  switch (await _bodyOf(trajectory, call.request, ModelRequestFromPieces.kind)) {
    case NothingRan(:final why) || StoppedPartway(:final why):
      return NothingRan(why);
    case Ran(output: final text):
      try {
        request = ModelRequestFromPieces.fromJson(JsonObject.decode(text));
      } on FormatException catch (e) {
        return NothingRan('not a model request: ${e.message}');
      }
  }
  Future<Outcome<String>> joined(TextFromPieces text) async {
    final texts = <String>[];
    for (final piece in text.pieces) {
      switch (await _bodyOf(trajectory, piece, ModelRequestPiece.kind)) {
        case NothingRan(:final why) || StoppedPartway(:final why):
          return NothingRan(why);
        case Ran(output: final text):
          try {
            texts.add(ModelRequestPiece.fromJson(JsonObject.decode(text)).text);
          } on FormatException catch (e) {
            return NothingRan('not a model request piece: ${e.message}');
          }
      }
    }
    return text.join(texts);
  }

  final systemPrompt = await joined(request.systemPrompt);
  final asked = await joined(request.request);
  return switch ((systemPrompt, asked)) {
    (NothingRan(:final why) || StoppedPartway(:final why), _) ||
    (_, NothingRan(:final why) || StoppedPartway(:final why)) => NothingRan(why),
    (Ran(output: final system), Ran(output: final text)) => await driver
        .askTheModel(call.signIn, call.model, system, text, report: report),
  };
}

/// The body of [entry], which must belong to [trajectory] and be of [kind],
/// as [DecidesActionsAndWritesToTheLogbook.entryOn] reads it; or
/// [NothingRan] with why not, since a read leaves the world as it was. The
/// kind is checked, since a loop may write a body of any shape under its
/// own kinds on its own chain.
/// [name]'s value in [headers], matched without regard to case, as HTTP
/// header names are; null when [headers] has none. A request draws its own
/// headers once each (is_effects' [ProposedRequest]), so there is never a
/// second one to merge.
String? _header(Map<String, String> headers, String name) {
  for (final MapEntry(key: key, value: value) in headers.entries) {
    if (key.toLowerCase() == name.toLowerCase()) return value;
  }
  return null;
}

Future<Outcome<String>> _bodyOf(
  Trajectory<Object?, Object?> trajectory,
  EntryId entry,
  String kind,
) async => switch (await trajectory._airlock.entryOn(trajectory.id, entry)) {
  NothingRan(:final why) || StoppedPartway(:final why) => NothingRan(why),
  Ran(output: (kind: final kept, :final body)) when kept == kind => Ran(body),
  Ran(output: (kind: final kept, body: _)) => NothingRan(
    'entry $entry is a $kept, not a $kind',
  ),
};

/// Sends [drawn], the requests a writer drew for a reply to [to], as
/// [signIn], in order, and reads what each posted with [posted], each id
/// made a [PostedMessage] by [answer].
///
/// Nothing is sent unless every request goes to an address [to] admits,
/// names no sign-in of its own, and — for a [RepliesWithPinnedBodyFields],
/// whose address alone never confines a reply to its conversation — has a
/// body [to] admits too, read exactly as it will be sent: the request's own
/// `content-type` header and its body bytes as text, never a re-encoded
/// copy. A missing `content-type` is a refusal, the same as a body that
/// doesn't admit: fail-closed. It stops at the first request that did not
/// post: [NothingRan] when that was the first and the server said nothing
/// posted; otherwise [StoppedPartway], with `done` the messages that
/// posted, and its `why` naming a message whose fate is unknown.
Future<Outcome<List<PostedMessage>>> _postReply<Id>(
  ReplyEndpoint to,
  SignIn signIn,
  List<ProposedRequest> drawn,
  CarriesOutWebRequests web,
  Outcome<Id> Function(WebResponse response) posted,
  PostedMessage Function(Id id) answer,
) async {
  if (drawn.isEmpty) return const NothingRan('the reply drew no requests');
  for (final (i, request) in drawn.indexed) {
    final at = 'request ${i + 1} of ${drawn.length}';
    if (!to.admitsAddress(request.origin, request.path)) {
      return NothingRan(
        '$at: ${request.origin}${request.path.value} is not the reply '
        "endpoint's address",
      );
    }
    if (to case RepliesWithPinnedBodyFields pinned) {
      final contentType = _header(request.headers, 'content-type');
      if (contentType == null ||
          !pinned.admitsBody(
            contentType: contentType,
            body: request.body ?? '',
          )) {
        return NothingRan(
          "$at: its content-type or body is not the reply endpoint's "
          'conversation',
        );
      }
    }
    if (request.signIn != null) {
      return NothingRan('$at: names its own sign-in');
    }
  }
  final done = <PostedMessage>[];
  for (final request in drawn) {
    final at = 'message ${done.length + 1} of ${drawn.length}';
    final granted = GrantedRequest.under(
      ProposedRequest(
        request.origin,
        method: request.method,
        path: request.path,
        signIn: signIn,
        headers: request.headers,
        body: request.body,
        keep: request.keep,
      ),
      to.redirectsStayUnder,
    );
    final Outcome<Id> read = switch (await web.carryOutWebRequest(granted)) {
      Ran(output: final response) => posted(response),
      final NothingRan nothing => nothing,
      StoppedPartway(:final why) => StoppedPartway(why: why, done: null),
    };
    switch (read) {
      case Ran(output: final id):
        done.add(answer(id));
      case NothingRan(:final why) when done.isEmpty:
        return NothingRan('$at: $why');
      case NothingRan(:final why):
        return StoppedPartway(why: '$at did not post: $why', done: done);
      case StoppedPartway(:final why):
        return StoppedPartway(
          why: '$at may have posted, unknown: $why',
          done: done,
        );
    }
  }
  return Ran(done);
}

/// Each of [requests] granted under its prefix in [allowed], in order; or
/// refused when [allowed] has not exactly one prefix per request, or one
/// doesn't cover its request's path, so nothing is sent unbounded.
Outcome<List<GrantedRequest>> _granted(
  List<ProposedRequest> requests,
  Allow allowed,
) {
  final prefixes = allowed.grantedPathPrefixes;
  if (prefixes.length != requests.length) {
    return NothingRan(
      'allowed with ${prefixes.length} granted path prefixes '
      'for ${requests.length} requests',
    );
  }
  final granted = <GrantedRequest>[];
  for (final (i, request) in requests.indexed) {
    if (!prefixes[i].covers(request.path)) {
      return NothingRan(
        'request ${i + 1}: ${request.path.value} is not under '
        'its granted prefix ${prefixes[i]}',
      );
    }
    granted.add(GrantedRequest.under(request, prefixes[i]));
  }
  return Ran(granted);
}

/// Sends [requests] to [web], exactly these, in order, stopping at the
/// first that fails without retrying.
Future<Outcome<List<WebResponse>>> _send(
  CarriesOutWebRequests web,
  List<GrantedRequest> requests,
) async {
  final responses = <WebResponse>[];
  for (final request in requests) {
    final at = 'request ${responses.length + 1} of ${requests.length}';
    switch (await web.carryOutWebRequest(request)) {
      case NothingRan(:final why) when responses.isEmpty:
        return NothingRan('$at: $why');
      case NothingRan(:final why):
        return StoppedPartway(why: '$at: $why', done: responses);
      case StoppedPartway(:final why, done: null):
        return StoppedPartway(
          why: '$at went out with no response: $why',
          done: responses,
        );
      case StoppedPartway(:final why, done: final WebResponse response):
        return StoppedPartway(why: '$at: $why', done: [...responses, response]);
      case Ran(output: final response)
          when response.status < 200 || response.status > 299:
        return StoppedPartway(
          why: '$at: ${response.status} ${response.refusedBecause ?? ''}'
              .trimRight(),
          done: [...responses, response],
        );
      case Ran(output: final response):
        responses.add(response);
    }
  }
  return Ran(responses);
}
