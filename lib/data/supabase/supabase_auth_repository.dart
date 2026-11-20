import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;
import 'package:supabase_flutter/supabase_flutter.dart' as sb show AuthException;

import '../../domain/entities/app_user.dart';
import '../../domain/repositories/auth_repository.dart';

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;
  GoTrueClient get _auth => _client.auth;

  AppUser? _map(User? u) {
    if (u == null) return null;
    return AppUser(
      uid: u.id,
      email: u.email ?? '',
      emailVerified: u.emailConfirmedAt != null,
      displayName: u.userMetadata?['display_name'] as String?,
    );
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on sb.AuthException catch (e) {
      final m = e.message.toLowerCase();
      throw AuthException(switch (e.code ?? '') {
        'invalid_credentials' => AuthErrorCode.invalidCredentials,
        'email_exists' || 'user_already_exists' => AuthErrorCode.emailInUse,
        'weak_password' => AuthErrorCode.weakPassword,
        'over_request_rate_limit' || 'over_email_send_rate_limit' => AuthErrorCode.tooManyRequests,
        'email_address_invalid' => AuthErrorCode.invalidEmail,
        _ when m.contains('network') => AuthErrorCode.network,
        _ => AuthErrorCode.unknown,
      });
    }
  }

  @override
  Stream<AppUser?> authStateChanges() async* {
    yield currentUser;
    yield* _auth.onAuthStateChange.map((s) => _map(s.session?.user));
  }

  @override
  AppUser? get currentUser => _map(_auth.currentUser);

  @override
  Future<void> signIn({required String email, required String password}) =>
      _guard(() => _auth.signInWithPassword(email: email, password: password));

  @override
  Future<void> signUp({required String email, required String password, required String displayName}) =>
      _guard(() => _auth.signUp(email: email, password: password, data: {'display_name': displayName.trim()}));

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<void> sendEmailVerification() => _guard(() async {
    final email = _auth.currentUser?.email;
    if (email != null) await _auth.resend(type: OtpType.signup, email: email);
  });

  @override
  Future<AppUser?> reload() => _guard(() async => _map((await _auth.getUser()).user));

  @override
  Future<void> updateDisplayName(String name) =>
      _guard(() => _auth.updateUser(UserAttributes(data: {'display_name': name.trim()})));

  @override
  Future<void> refreshToken() => _guard(() => _auth.refreshSession());
}
