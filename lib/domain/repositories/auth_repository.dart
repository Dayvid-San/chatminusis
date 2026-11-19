import '../entities/app_user.dart';

/// Error codes surfaced by any [AuthRepository] implementation.
enum AuthErrorCode { invalidEmail, invalidCredentials, emailInUse, weakPassword, tooManyRequests, network, unknown }

class AuthException implements Exception {
  const AuthException(this.code);
  final AuthErrorCode code;

  @override
  String toString() => 'AuthException($code)';
}

/// Authentication contract. UI and view models depend only on this.
abstract class AuthRepository {
  Stream<AppUser?> authStateChanges();
  AppUser? get currentUser;

  Future<void> signIn({required String email, required String password});
  Future<void> signUp({required String email, required String password, required String displayName});
  Future<void> signOut();

  Future<void> sendEmailVerification();

  /// Refreshes the current user (e.g. after the email link was clicked) and
  /// returns the updated value.
  Future<AppUser?> reload();

  Future<void> updateDisplayName(String name);

  /// Fresh ID token, so security rules see an updated `email_verified`.
  Future<void> refreshToken();
}
