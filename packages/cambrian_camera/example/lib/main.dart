import 'package:flutter/material.dart';

import 'hitl_screen.dart';

void main() {
  runApp(const HitlApp());
}

/// Hardware-in-the-loop verification app for the cambrian_camera plugin.
///
/// The home screen is the [HitlScreen] harness — one button per host method
/// plus live stream panels — used to run the Phase-3 on-device matrix.
class HitlApp extends StatelessWidget {
  const HitlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cambrian Camera HITL',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const HitlScreen(),
    );
  }
}
