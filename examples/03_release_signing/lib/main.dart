import 'package:flutter/material.dart';

void main() => runApp(const HelloOkaApp());

class HelloOkaApp extends StatelessWidget {
  const HelloOkaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('Release me')),
      body: const Center(child: Text('Built without Gradle — release!')),
    ),
  );
}
