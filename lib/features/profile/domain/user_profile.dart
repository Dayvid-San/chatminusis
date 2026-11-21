/// Public profile, visible to people who know the exact nickname or share a
/// conversation. Never contains the email.
class UserProfile {
  const UserProfile({required this.uid, required this.nickname, required this.displayName});

  final String uid;
  final String nickname;
  final String displayName;
}
