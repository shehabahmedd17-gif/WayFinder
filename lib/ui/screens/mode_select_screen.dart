// STUB — wired up in Step 3 (STT + state machine).
// Presents outdoor/indoor choice via voice; up to kModeSelectRetries attempts.
import 'package:flutter/material.dart';

class ModeSelectScreen extends StatelessWidget {
  const ModeSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text('Mode Select', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}
