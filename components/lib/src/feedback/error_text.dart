import 'package:flutter/material.dart';

/// An error line. Renders nothing for an empty message.
class ErrorText extends StatelessWidget {
  const ErrorText(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => message.isEmpty
      ? const SizedBox.shrink()
      : Text(message, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600));
}
