import 'package:flutter/foundation.dart';

import '../models/mission_message.dart';
import 'global_log.dart';

const _tag = 'ack';

typedef MissionSender = Future<bool> Function(int dest, MissionMessage message);

/// Why a command did not get away.
///
/// Only two remain, and neither is about acknowledgement. [linkDown] is the
/// transport refusing the write, which is a fault on this phone. [rejected] is
/// the drone answering `NACK` -- a considered refusal it chose to send, not the
/// absence of something we hoped for.
enum AckFailureKind { rejected, linkDown }

class AckFailure {
  final int droneId;
  final MissionMessage message;
  final AckFailureKind kind;
  final NackError? reason;
  final DateTime at;

  const AckFailure({
    required this.droneId,
    required this.message,
    required this.kind,
    required this.at,
    this.reason,
  });

  String get description => switch (kind) {
        AckFailureKind.rejected =>
          '${message.type} rejected: ${reason?.wire ?? 'unknown'}',
        AckFailureKind.linkDown => 'Could not transmit ${message.type} — link down',
      };

  bool get isCritical => kind != AckFailureKind.rejected;
}

/// Sends commands and remembers refusals. Delivery belongs to the radio.
///
/// This class used to be the reliability layer: it held every command open,
/// resent it on a timer, and reported a failure when no `ACK` came back. All of
/// that is gone, and the reason it was wrong is the layering.
///
/// A retry from here travels phone → USB → ESP → air and lands in the same
/// four-slot outbound queue the original is already sitting in. Under loss that
/// made things worse rather than better: more frames offered to a channel already
/// dropping a third of them, with the overflow silently discarded. Retrying
/// belongs where the ACK verdict is known in milliseconds and no queue is crossed
/// twice — the LoRa layer, which holds pending frames itself and repeats them
/// until they land.
///
/// So a command is now sent exactly once, and whether it was obeyed is read from
/// what the drone *does*: `EVT`, `ARRIVED`, a changed state in `TELEM`. Those
/// repeat of their own accord, which a single unrepeated `ACK` never did — and
/// losing one of those ACKs was the most common way a healthy flight ended.
class CommandTracker extends ChangeNotifier {
  CommandTracker({
    required MissionSender sender,
    required List<int> knownDrones,
  })  : _send = sender,
        _knownDrones = List.unmodifiable(knownDrones);

  final MissionSender _send;
  final List<int> _knownDrones;

  final _seq = SeqCounter();
  final Map<int, AckFailure> _failures = {};

  void Function(AckFailure failure)? onFailed;

  List<AckFailure> get failures =>
      _failures.values.toList()..sort((a, b) => b.at.compareTo(a.at));

  bool get hasCriticalFailure => _failures.values.any((f) => f.isCritical);

  AckFailure? failureFor(int droneId) => _failures[droneId];

  /// A sequence number for a phone-originated message that is not a command.
  /// Shares the command counter so every phone→drone message has a distinct `q`.
  int nextSeq() => _seq.take();

  /// Sends one command and returns the `q` it went out with.
  ///
  /// One transmission, no retry, no pending state. The `q` still has to be
  /// distinct per message because the drone dedupes on it: if the radio ever
  /// delivers a frame twice, a repeated `MOVE` would step the formation a vertex
  /// too far.
  Future<int> send(
    MissionMessage Function(int seq) build, {
    required int dest,
    List<int>? awaitAckFrom,
  }) async {
    final seq = _seq.take();
    final message = build(seq);
    logTrace(_tag, '${message.type} q=$seq dest=$dest');

    final accepted = await _send(dest, message);
    if (!accepted) {
      final expected =
          awaitAckFrom ?? (dest == kBroadcastAddress ? _knownDrones : <int>[dest]);
      for (final droneId in expected) {
        final failure = AckFailure(
          droneId: droneId,
          message: message,
          kind: AckFailureKind.linkDown,
          at: DateTime.now(),
        );
        _failures[droneId] = failure;
        logError('Drone $droneId: ${failure.description}', _tag);
        onFailed?.call(failure);
      }
      notifyListeners();
    }
    return seq;
  }

  /// Sends one message and forgets it. Identical to [send] but for the absence of
  /// a link-down report, which a keepalive does not deserve.
  Future<void> ping(int dest, MissionMessage Function(int seq) build) async {
    await _send(dest, build(_seq.take()));
  }

  void handleIncoming(int from, MissionMessage message) {
    switch (message) {
      case AckMessage(:final respondingTo):
        // The drones no longer send these. A stray one from older firmware is
        // contact and nothing more.
        logTrace(_tag, 'ACK from $from for q=$respondingTo (unexpected)');
        _clearFailureOnContact(from);

      case NackMessage(:final respondingTo, :final error):
        // BUSY answering a start command is the drone saying it is already
        // running one, which is agreement rather than refusal. Landing a drone
        // for that is perverse — it cost three flights on 2026-08-11.
        if (error == NackError.busy) {
          logWarn('Drone $from answered BUSY to q=$respondingTo — it is already '
              'running a mission, so nothing needs starting', _tag);
          _clearFailureOnContact(from);
          return;
        }

        // A refusal the drone chose to send. It says what will NOT happen, which
        // no silence can, so it is the one failure still worth acting on.
        final failure = AckFailure(
          droneId: from,
          message: message,
          kind: AckFailureKind.rejected,
          reason: error,
          at: DateTime.now(),
        );
        _failures[from] = failure;
        logWarn('Drone $from rejected q=$respondingTo: ${error.wire}', _tag);
        notifyListeners();
        onFailed?.call(failure);

      default:
        _clearFailureOnContact(from);
    }
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
    _failures.clear();
    notifyListeners();
  }
}
