import 'package:flutter/material.dart';

/// Asks a yes/no question. Returns true only when the user confirms.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirmar',
  String cancelLabel = 'Cancelar',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancelLabel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
        ],
      ),
    ) ??
    false;
