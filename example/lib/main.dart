import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

// The dev-session asset probes (ADR-0037 §6b / gate_dev_assets.sh).
// `evaluate` cannot await, so the probe is two-phase: evaluate
// [refreshHelloAsset] (fires the async reload inside the app), then read
// the cached fingerprint synchronously via [helloAssetFingerprint] —
// length + byte-sum, so content changes are visible at a constant size.
// NOTE: the bootstrap below is deliberately the STANDARD
// WidgetsFlutterBinding — mcp_toolkit's `bootstrapFlutter` suppresses
// framework service extension registration (ext.flutter.* never
// appear), which the live stack's reassemble/evict calls need.
int _helloFingerprint = 0;

Future<void> refreshHelloAsset() async {
  final d = await rootBundle.load('assets/hello.txt');
  var sum = 0;
  for (final b in d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)) {
    sum += b;
  }
  _helloFingerprint = d.lengthInBytes * 1000003 + sum;
}

int helloAssetFingerprint() => _helloFingerprint;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await refreshHelloAsset();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(final BuildContext context) => MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({required this.title, super.key});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(final BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      title: Text(widget.title),
    ),
    body: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Text('You have pushed the button this many times:'),
          Text(
            '$_counter',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ],
      ),
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: _incrementCounter,
      tooltip: 'Increment',
      child: const Icon(Icons.add),
    ),
  );
}
