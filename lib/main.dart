import 'package:flutter/material.dart';

import 'features/connection/connection_page.dart';

void main() => runApp(const PocketSshApp());

class PocketSshApp extends StatelessWidget {
  const PocketSshApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff66dcb8),
      brightness: Brightness.dark,
      surface: const Color(0xff11171f),
    );
    return MaterialApp(
      title: 'Pocket SSH',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colors,
        scaffoldBackgroundColor: colors.surface,
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(14))),
        ),
      ),
      home: const ConnectionPage(),
    );
  }
}
