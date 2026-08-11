import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/mission_message.dart';
import 'global_log.dart';

const _tag = 'ack';

typedef MissionSender = Future<bool> Function(int dest, MissionMessage message);

enum AckFailureKind { silence, rejected, linkDown }

class AckFailure {
  final int droneId;
  final MissionMessage message;
  final AckFailureKind kind;
  final NackError? reason;
  final int attempts;
  final DateTime at;

  const AckFailure({
    required this.droneId,
    required this.message,
    required this.kind,
    required this.attempts,
    required this.at,
    this.reason,
  });

  String get description => switch (kind) {
        AckFailureKind.silence =>
          'No ACK for ${message.type} after $attempts attempt${attempts == 1 ? '' : 's'}',
        AckFailureKind.rejected =>
          '${message.type} rejected: ${reason?.wire ?? 'unknown'}',
        AckFailureKind.linkDown => 'Could not transmit ${message.type} — link down',
      };

  bool get isCritical => kind != AckFailureKind.rejected;
}

class _PendingGroup {
  _PendingGroup({
    required this.seq,
    required this.dest,
    required this.message,
    required this.awaiting,
  });

  final int seq;
  final int dest;
  final MissionMessage message;
  final Set<int> awaiting;

  int attempts = 1;
  Timer? timer;
}

class CommandTracker extends ChangeNotifier {
  CommandTracker({
    required MissionSender sender,
    required List<int> knownDrones,
    this.ackTimeout = const Duration(milliseconds: 2000),
    this.maxAttempts = 3,
  })  : _send = sender,
        _knownDrones = List.unmodifiable(knownDrones);

  final MissionSender _send;
  final List<int> _knownDrones;

  /// Settable while the app runs, from the link tab. A timer already armed
  /// keeps the value it was armed with; every retry and every later message
  /// picks up the new one.
  Duration ackTimeout;
  int maxAttempts;

  final _seq = SeqCounter();
  final Map<int, _PendingGroup> _groups = {};
  final Map<int, AckFailure> _failures = {};

  void Function(int droneId, MissionMessage command, AckMessage ack)? onAcknowledged;
  void Function(AckFailure failure)? onFailed;

  List<AckFailure> get failures =>
      _failures.values.toList()..sort((a, b) => b.at.compareTo(a.at));

  bool get hasCriticalFailure => _failures.values.any((f) => f.isCritical);

  AckFailure? failureFor(int droneId) => _failures[droneId];

  bool isAwaitingAck(int droneId) =>
      _groups.values.any((g) => g.awaiting.contains(droneId));

  /// A sequence number for a phone-originated message that is not a command --
  /// today, the ACKs the ground station owes for MINE and SCAN. Shares the
  /// command counter so every phone→drone message has a distinct `q`.
  int nextSeq() => _seq.take();

  /// Sends one command and returns the `q` it went out with, so the caller can
  /// [withdraw] it later. Tracking continues in the background.
  Future<int> send(
    MissionMessage Function(int seq) build, {
    required int dest,
    List<int>? awaitAckFrom,
  }) async {
    final seq = _seq.take();
    final message = build(seq);

    final expected =
        awaitAckFrom ?? (dest == kBroadcastAddress ? _knownDrones : <int>[dest]);

    if (!message.expectsAck) {
      logTrace(_tag, '${message.type} q=$seq dest=$dest (no ACK expected)');
      await _send(dest, message);
      return seq;
    }

    final group = _PendingGroup(
      seq: seq,
      dest: dest,
      message: message,
      awaiting: expected.toSet(),
    );
    _groups[seq] = group;
    logTrace(_tag, '${message.type} q=$seq dest=$dest '
        'awaiting=[${expected.join(",")}] timeout=${ackTimeout.inMilliseconds}ms');
    notifyListeners();

    final accepted = await _send(dest, message);
    if (!accepted) {
      _failGroup(group, AckFailureKind.linkDown);
      return seq;
    }
    _arm(group);
    return seq;
  }

  /// Sends one message and forgets it: no retries, no failure if it is lost.
  ///
  /// For traffic whose whole purpose is to be sent rather than to be obeyed --
  /// the keepalive that stops a hovering drone timing out. Tracking it would be
  /// wrong twice over: a lost keepalive is not a drone fault, and recording it
  /// as one would raise a failure banner over a perfectly healthy aircraft. The
  /// next one is along in a few seconds anyway, which is a better retry than the
  /// tracker's.
  ///
  /// Still takes a `q` from the shared counter, so every phone→drone message has
  /// a distinct one (PROTOCOL.md §3).
  Future<void> ping(int dest, MissionMessage Function(int seq) build) async {
    await _send(dest, build(_seq.take()));
  }

  /// Settle a pending command from evidence other than its own ACK.
  ///
  /// An ACK is one way to learn a command was obeyed; it is not the only way and
  /// it is the least reliable, because it is sent once and never repeated. The
  /// drone's *behaviour* says the same thing and says it repeatedly: a drone that
  /// reports `MISSION_START` has started the demo, one that reports `ARRIVED` at
  /// the point a `MOVE` named has flown that `MOVE`, one that answers `BUSY` is
  /// telling us outright that it already holds the command.
  ///
  /// On 2026-08-11 the cost of not doing this was three destroyed flights. A
  /// `START_DEMO` was accepted, its ACK was lost, the retry was refused `BUSY`,
  /// and the group sat there until its attempts ran out -- at which point the app
  /// landed a drone that had by then acknowledged two `MOVE`s and reported an
  /// arrival. The ACK it was waiting for could never arrive: the drone had
  /// consumed that `q` and would answer `BUSY` for ever.
  ///
  /// [proves] picks the commands this evidence settles. Nothing is reported to
  /// [onAcknowledged] -- there is no `AckMessage` to hand over, and callers that
  /// need the ACK's payload (the anchor in a `START_DEMO` ACK) have to recover it
  /// from the evidence itself.
  void confirm(int droneId, bool Function(MissionMessage) proves, String evidence) {
    final settled = _groups.values
        .where((g) => g.awaiting.contains(droneId) && proves(g.message))
        .toList();
    for (final group in settled) {
      logInfo('${group.message.type} q=${group.seq} confirmed by $evidence after '
          '${group.attempts} attempt(s) — no ACK needed', _tag);
      _resolve(droneId, group.seq);
    }
    if (settled.isNotEmpty) _clearFailureOnContact(droneId);
  }

  /// Stops chasing an ACK for [seq]: no more retries, and no failure reported.
  ///
  /// For a command the drone can still usefully act on, letting the retries run
  /// is right. For one the ground station has since superseded it is not: the
  /// retry reuses the original `q`, and once it lands outside the drone's
  /// retransmission window it is a *new* command carrying an order that no
  /// longer reflects where the formation is. Withdrawing is not a failure —
  /// nothing is wrong with the drone — so it must not reach [onFailed], which
  /// would land it.
  void withdraw(int seq) {
    final group = _groups.remove(seq);
    if (group == null) return;
    group.timer?.cancel();
    logInfo('${group.message.type} q=$seq withdrawn after '
        '${group.attempts} attempt(s) — superseded', _tag);
    notifyListeners();
  }

  void _arm(_PendingGroup group) {
    group.timer?.cancel();
    group.timer = Timer(ackTimeout, () => _onTimeout(group));
  }

  Future<void> _onTimeout(_PendingGroup group) async {
    if (!_groups.containsKey(group.seq)) return;

    if (group.attempts >= maxAttempts) {
      _failGroup(group, AckFailureKind.silence);
      return;
    }

    group.attempts++;

    logWarn(
      'Retrying ${group.message.type} (attempt ${group.attempts}/$maxAttempts) — '
      'awaiting ${group.awaiting.join(", ")}',
      _tag,
    );

    final accepted = await _send(group.dest, group.message); // same q, so drone dedupes
    if (!accepted) {
      _failGroup(group, AckFailureKind.linkDown);
      return;
    }
    if (_groups.containsKey(group.seq)) _arm(group);
  }

  void _failGroup(_PendingGroup group, AckFailureKind kind) {
    group.timer?.cancel();
    _groups.remove(group.seq);

    for (final droneId in group.awaiting) {
      final failure = AckFailure(
        droneId: droneId,
        message: group.message,
        kind: kind,
        attempts: group.attempts,
        at: DateTime.now(),
      );
      _failures[droneId] = failure;
      logError('Drone $droneId: ${failure.description}', _tag);
      onFailed?.call(failure);
    }
    notifyListeners();
  }

  void handleIncoming(int from, MissionMessage message) {
    switch (message) {
      case AckMessage(:final respondingTo):
        logTrace(_tag, 'ACK from $from for q=$respondingTo');
        final acked = _groups[respondingTo]?.message;
        _resolve(from, respondingTo);
        _clearFailureOnContact(from);
        if (acked != null) {
          onAcknowledged?.call(from, acked, message);
        }

      case NackMessage(:final respondingTo, :final error):
        final group = _groups[respondingTo];

        // BUSY answering a start command is the drone telling us it is already
        // running one. That is not a rejection, it is a *confirmation* -- and the
        // strongest kind, because the drone is reporting its own state rather
        // than echoing our frame. Whether this is attempt 1 (a demo left running
        // from before) or attempt 6 (our own duplicate arriving after the first
        // was accepted and its ACK lost), the command is in force.
        //
        // Earlier this only silenced the retransmissions and let the attempt
        // clock run out, on the reasoning that without the ACK we still did not
        // know where the drone was. That was wrong twice: the ACK could never
        // arrive, because the drone had consumed the `q` and would answer BUSY
        // for ever; and by the time the clock expired the drone had told us where
        // it was several times over. On 2026-08-11 it cost three flights.
        // Only from attempt 2 on. A BUSY answering the *first* copy cannot be our
        // own duplicate -- the drone was already running something we did not
        // start -- and that is a real rejection the operator should see.
        if (group != null &&
            error == NackError.busy &&
            group.attempts > 1 &&
            group.message is StartDemoMessage) {
          logWarn(
            '${group.message.type} q=$respondingTo answered BUSY on attempt '
            '${group.attempts} — drone $from already holds it, which settles it. '
            'The anchor comes from its arrival report instead of this ACK',
            _tag,
          );
          _resolve(from, respondingTo);
          _clearFailureOnContact(from);
          return;
        }

        _resolve(from, respondingTo);
        if (group != null) {
          _failures[from] = AckFailure(
            droneId: from,
            message: group.message,
            kind: AckFailureKind.rejected,
            reason: error,
            attempts: group.attempts,
            at: DateTime.now(),
          );
          logWarn('Drone $from rejected ${group.message.type}: ${error.wire}', _tag);
          notifyListeners();
          onFailed?.call(_failures[from]!);
        }

      default:
        // Any frame at all settles an outstanding probe: a probe asks nothing
        // more than "are you there", and this is the answer whatever its type.
        // It also stops probes piling up on a drone that is merely quiet.
        confirm(from, (m) => m is StatusMessage, '${message.type} from the drone');
        _clearFailureOnContact(from);
    }
  }

  void _resolve(int from, int seq) {
    final group = _groups[seq];
    if (group == null) {
      logTrace(_tag, 'no pending command for q=$seq (late or duplicate ACK)');
      return;
    }

    group.awaiting.remove(from);
    if (group.awaiting.isEmpty) {
      group.timer?.cancel();
      _groups.remove(seq);
      logTrace(_tag, 'q=$seq fully acknowledged');
    } else {
      logTrace(_tag, 'q=$seq still awaiting [${group.awaiting.join(",")}]');
    }
    notifyListeners();
  }

  void _clearFailureOnContact(int droneId) {
    final existing = _failures[droneId];
    if (existing == null || existing.kind == AckFailureKind.rejected) return;
    _failures.remove(droneId);
    logInfo('Drone $droneId is responding again', _tag);
    notifyListeners();
  }

  void dismissFailure(int droneId) {
    if (_failures.remove(droneId) != null) notifyListeners();
  }

  void dismissAll() {
    if (_failures.isEmpty) return;
    _failures.clear();
    notifyListeners();
  }

  void reset() {
    for (final g in _groups.values) {
      g.timer?.cancel();
    }
    _groups.clear();
    _failures.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final g in _groups.values) {
      g.timer?.cancel();
    }
    _groups.clear();
    super.dispose();
  }
}
