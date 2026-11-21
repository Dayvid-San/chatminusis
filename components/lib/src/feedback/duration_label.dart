/// Short label for a duration: "30 s", "5 min", "2 h", "1 dia".
String durationLabel(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return '${d.inHours} h';
  final days = d.inDays;
  return days == 1 ? '1 dia' : '$days dias';
}
