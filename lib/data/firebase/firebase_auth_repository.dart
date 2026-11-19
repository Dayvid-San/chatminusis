import 'package:firebase_auth/firebase_auth.dart';

import '../../domain/entities/app_user.dart';
import '../../domain/repositories/auth_repository.dart';

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository(this._auth);

  final FirebaseAuth _auth;

  AppUser? _map(User? user) {
    if (user == null) return null;
    return AppUser(
      uid: user.uid,
      email: user.email ?? '',
      emailVerified: user.emailVerified,
      displayName: user.displayName,
    );
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseAuthException catch (e) {
      throw AuthException(_code(e.code));
    }
  }

  static AuthErrorCode _code(String code) => switch (code) {
    'invalid-email' => AuthErrorCode.invalidEmail,
    'user-not-found' || 'wrong-password' || 'invalid-credential' || 'user-disabled' => AuthErrorCode.invalidCredentials,
    'email-already-in-use' => AuthErrorCode.emailInUse,
    'weak-password' || 'password-does-not-meet-requirements' => AuthErrorCode.weakPassword,
    'too-many-requests' => AuthErrorCode.tooManyRequests,
    'network-request-failed' => AuthErrorCode.network,
    _ => AuthErrorCode.unknown,
  };

  @override
  Stream<AppUser?> authStateChanges() => _auth.userChanges().map(_map);

  @override
  AppUser? get currentUser => _map(_auth.currentUser);

  @override
  Future<void> signIn({required String email, required String password}) =>
      _guard(() => _auth.signInWithEmailAndPassword(email: email, password: password));

  @override
  Future<void> signUp({required String email, required String password, required String displayName}) =>
      _guard(() async {
        final credential = await _auth.createUserWithEmailAndPassword(email: email, password: password);
        final user = credential.user;
        if (user == null) return;
        await user.updateDisplayName(displayName.trim());
        await user.sendEmailVerification();
        await user.reload();
      });

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<void> sendEmailVerification() => _guard(() async => _auth.currentUser?.sendEmailVerification());

  @override
  Future<AppUser?> reload() => _guard(() async {
    await _auth.currentUser?.reload();
    return currentUser;
  });

  @override
  Future<void> updateDisplayName(String name) => _guard(() async {
    await _auth.currentUser?.updateDisplayName(name.trim());
    await _auth.currentUser?.reload();
  });

  @override
  Future<void> reauthenticate(String password) => _guard(() async {
    final user = _auth.currentUser;
    if (user == null || user.email == null) return;
    await user.reauthenticateWithCredential(EmailAuthProvider.credential(email: user.email!, password: password));
    await user.getIdToken(true); // the new token carries the new auth_time
  });

  @override
  Future<void> refreshToken() => _guard(() async => _auth.currentUser?.getIdToken(true));
}
