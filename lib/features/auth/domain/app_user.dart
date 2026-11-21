/// Authenticated account, independent of the backend (Firebase or Supabase).
class AppUser {
  const AppUser({required this.uid, required this.email, required this.emailVerified, this.displayName});

  final String uid;
  final String email;
  final bool emailVerified;
  final String? displayName;

  /// Name shown in the UI: the chosen display name, or the email prefix.
  String get visibleName {
    final name = displayName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    return email.split('@').first;
  }
}
