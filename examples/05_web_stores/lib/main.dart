import 'package:flutter/material.dart';

void main() => runApp(const WebOkaApp());

class WebOkaApp extends StatelessWidget {
  const WebOkaApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('One shell, any storefront.'))),
  );
}
