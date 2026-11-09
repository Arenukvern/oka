import 'package:oka_dart_kernel/src/gate/supervisor_control_channel.dart';

Map<int, String> fixtureEscapedFromTranscript(String transcript) => {
      for (final r in fixtureEscapedReportsFromTranscript(transcript))
        r.pid: r.token,
    };
