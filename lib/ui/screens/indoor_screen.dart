// STUB — wired up in Step 3.
// Runs obstacle detection only (no GPS, no routing).
import 'package:flutter/material.dart';

class IndoorScreen extends StatelessWidget {
  const IndoorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text('Indoor Mode', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}
