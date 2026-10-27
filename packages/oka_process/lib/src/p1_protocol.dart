import 'package:meta/meta.dart';

/// Host → leader control commands (p1).
enum OwnedSessionControlCommand {
  term('term'),
  kill('kill'),
  settle('settle');

  const OwnedSessionControlCommand(this.wireName);

  final String wireName;
}

/// Parsed leader → host status line (p1).
@immutable
sealed class OwnedSessionStatusLine {
  const OwnedSessionStatusLine();
}

final class StatusStarted extends OwnedSessionStatusLine {
  const StatusStarted();
}

final class StatusTermForwarded extends OwnedSessionStatusLine {
  const StatusTermForwarded();
}

final class StatusKilledGroup extends OwnedSessionStatusLine {
  const StatusKilledGroup();
}

final class StatusSettled extends OwnedSessionStatusLine {
  const StatusSettled();
}

final class StatusExit extends OwnedSessionStatusLine {
  const StatusExit(this.waitStatus);

  final int waitStatus;
}

final class StatusUnsettled extends OwnedSessionStatusLine {
  const StatusUnsettled(this.reason);

  final String reason;
}

final class StatusGraceful extends OwnedSessionStatusLine {
  const StatusGraceful(this.payload);

  final String payload;
}

/// Parses one newline-stripped control line (after marker authentication).
OwnedSessionStatusLine? parseOwnedSessionStatusLine(String line) {
  if (line == 'started') return const StatusStarted();
  if (line == 'term-forwarded') return const StatusTermForwarded();
  if (line == 'killed-group') return const StatusKilledGroup();
  if (line == 'settled') return const StatusSettled();
  if (line.startsWith('exit:')) {
    final value = int.tryParse(line.substring('exit:'.length));
    if (value != null) return StatusExit(value);
  }
  if (line.startsWith('unsettled:')) {
    return StatusUnsettled(line.substring('unsettled:'.length));
  }
  if (line.startsWith('graceful:')) {
    return StatusGraceful(line.substring('graceful:'.length));
  }
  return null;
}

/// First stderr bootstrap line: `<marker>:ready:<sid>:p1:<impl>`.
@immutable
final class OwnedSessionReadyLine {
  const OwnedSessionReadyLine({
    required this.marker,
    required this.sessionId,
    required this.protocolRevision,
    required this.implementation,
  });

  final String marker;
  final int sessionId;
  final int protocolRevision;
  final String implementation;

  static final _pattern = RegExp(r'^(.+):ready:(\d+):p(\d+):(\w+)$');

  static OwnedSessionReadyLine? tryParse(String line) {
    final match = _pattern.firstMatch(line.trim());
    if (match == null) return null;
    final sid = int.tryParse(match.group(2)!);
    final protocol = int.tryParse(match.group(3)!);
    if (sid == null || protocol == null) return null;
    return OwnedSessionReadyLine(
      marker: match.group(1)!,
      sessionId: sid,
      protocolRevision: protocol,
      implementation: match.group(4)!,
    );
  }
}

/// Maps a POSIX wait status integer to [SettlementSettled] fields.
({int? exitCode, int? signal}) waitStatusToSettlement(int waitStatus) {
  if (waitStatus & 0x7f != 0) {
    return (exitCode: null, signal: waitStatus & 0x7f);
  }
  return (exitCode: waitStatus >> 8, signal: null);
}
