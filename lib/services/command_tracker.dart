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

  Future<void> send(
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
      return;
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
      return;
    }
    _arm(group);
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
