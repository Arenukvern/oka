// Ensures oka_harness API compiles against pub-hosted flutter_mcp_harness.
import 'package:flutter_mcp_harness/flutter_mcp_harness.dart';
import 'package:oka_harness/oka_harness.dart';

Future<void> main() async {
  final target = AndroidAppTarget(projectDir: '.', logcat: false);
  // ignore: deprecated_member_use
  final LaunchedApp launched = await target.launch(build: false);
  await AndroidAppTarget.stopCooperatively(launched);
}
