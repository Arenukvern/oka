import 'dart:convert';
import 'dart:io';

typedef ToolProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
      Encoding? stdoutEncoding,
      Encoding? stderrEncoding,
    });

Future<ProcessResult> runToolProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  Encoding? stdoutEncoding = systemEncoding,
  Encoding? stderrEncoding = systemEncoding,
}) => Process.run(
  executable,
  arguments,
  environment: environment,
  stdoutEncoding: stdoutEncoding,
  stderrEncoding: stderrEncoding,
);
