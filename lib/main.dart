import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const AlpineRunnerApp());
}

class AlpineRunnerApp extends StatelessWidget {
  const AlpineRunnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alpine Runner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}
