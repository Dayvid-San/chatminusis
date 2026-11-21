import 'dart:async';

import 'package:flutter/widgets.dart';

/// Rebuilds [builder] once when [instant] passes (and again if [instant]
/// changes), so something that expires on screen disappears by itself.
/// With a null [instant] it just builds.
class RebuildAt extends StatefulWidget {
  const RebuildAt({super.key, required this.instant, required this.builder, this.now = DateTime.now});

  final DateTime? instant;
  final WidgetBuilder builder;
  final DateTime Function() now;

  @override
  State<RebuildAt> createState() => _RebuildAtState();
}

class _RebuildAtState extends State<RebuildAt> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(RebuildAt old) {
    super.didUpdateWidget(old);
    if (old.instant != widget.instant) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final at = widget.instant;
    if (at == null) return;
    final wait = at.difference(widget.now());
    if (wait.isNegative) return;
    _timer = Timer(wait + const Duration(milliseconds: 20), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
