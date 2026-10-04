import 'package:flutter/material.dart';

Future<void> main() => runApp(const BrandedApp());

class BrandedApp extends StatelessWidget {
  const BrandedApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(
      body: Center(child: Text('Same code, whichever brand built me.')),
    ),
  );
}
