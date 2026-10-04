import 'package:flutter/material.dart';

void main() => runApp(const HelloOkaApp());

class HelloOkaApp extends StatelessWidget {
  const HelloOkaApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('Hello from a no-Gradle build!'))),
  );
}
