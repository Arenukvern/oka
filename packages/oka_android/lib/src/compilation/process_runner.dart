import 'dart:io';

typedef AndroidProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });

Future<ProcessResult> runAndroidProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => Process.run(executable, arguments, environment: environment);
