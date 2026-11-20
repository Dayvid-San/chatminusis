import 'dart:async';

import 'package:myapp/features/auth/domain/app_user.dart';
import 'package:myapp/features/auth/domain/auth_repository.dart';

class FakeAuthRepository implements AuthRepository {
  final _controller = StreamController<AppUser?>.broadcast();
  AppUser? user;
  String password = 'correct-pass-1';
  bool verifyOnReload = false;
  int verificationEmails = 0;
  int tokenRefreshes = 0;

  void _emit() => _controller.add(user);

  @override
  Stream<AppUser?> authStateChanges() => _controller.stream;

  @override
  AppUser? get currentUser => user;

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (password != this.password) throw const AuthException(AuthErrorCode.invalidCredentials);
    user = AppUser(uid: 'u1', email: email, emailVerified: true);
    _emit();
  }

  @override
  Future<void> signUp({required String email, required String password, required String displayName}) async {
    user = AppUser(uid: 'u1', email: email, emailVerified: false, displayName: displayName);
    verificationEmails++;
    _emit();
  }

  @override
  Future<void> signOut() async {
    user = null;
    _emit();
  }

  @override
  Future<void> sendEmailVerification() async => verificationEmails++;

  @override
  Future<AppUser?> reload() async {
    final u = user;
    if (u != null && verifyOnReload) {
      user = AppUser(uid: u.uid, email: u.email, emailVerified: true, displayName: u.displayName);
    }
    return user;
  }

  @override
  Future<void> updateDisplayName(String name) async {
    final u = user!;
    user = AppUser(uid: u.uid, email: u.email, emailVerified: u.emailVerified, displayName: name);
  }

  int reauths = 0;

  @override
  Future<void> reauthenticate(String password) async {
    if (password != this.password) throw const AuthException(AuthErrorCode.invalidCredentials);
    reauths++;
  }

  @override
  Future<void> refreshToken() async => tokenRefreshes++;
}
