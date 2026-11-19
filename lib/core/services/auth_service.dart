import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  final FirebaseAuth _firebaseAuth;

  AuthService(this._firebaseAuth);

  User? get currentUser => _firebaseAuth.currentUser;

  Stream<User?> get authStateChanges => _firebaseAuth.authStateChanges();

  Future<UserCredential> signIn(String email, String password) async {
    try {
      return await _firebaseAuth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException {
      rethrow;
    }
  }

  Future<UserCredential> signUp(
    String email,
    String password, {
    String? displayName,
  }) async {
    try {
      final credential = await _firebaseAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (displayName != null && displayName.trim().isNotEmpty) {
        await credential.user?.updateDisplayName(displayName.trim());
        await credential.user?.reload();
      }
      return credential;
    } on FirebaseAuthException {
      rethrow;
    }
  }

  Future<void> updateDisplayName(String name) async {
    final user = _firebaseAuth.currentUser;
    if (user == null) return;
    await user.updateDisplayName(name.trim());
    await user.reload();
  }

  Future<void> signOut() async {
    await _firebaseAuth.signOut();
  }
}
