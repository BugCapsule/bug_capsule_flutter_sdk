import 'package:flutter/widgets.dart';

/// Safe replacement for a failed widget; requires no MaterialApp or Navigator.
class BugCapsuleErrorFallback extends StatelessWidget {
  const BugCapsuleErrorFallback({super.key});

  @override
  Widget build(BuildContext context) => const Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: Color(0xFFF8FAFC),
      child: ClipRect(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Text(
            'This part of the screen could not load. Please go back and open it again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF334155), fontSize: 16),
          ),
        ),
      ),
    ),
  );
}
