import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../core/services/auth_service.dart';

class AuthViewModel extends ChangeNotifier {
  final AuthService _authService;

  bool _isLoading = false;
  String _errorMessage = '';

  AuthViewModel(this._authService);

  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;
  User? get currentUser => _authService.currentUser;
  Stream<User?> get authStateChanges => _authService.authStateChanges;

  void clearError() {
    if (_errorMessage.isEmpty) {
      return;
    }

    _errorMessage = '';
    notifyListeners();
  }

  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();
  }

  Future<bool> signIn(String email, String password) async {
    _setLoading(true);
    _setError('');
    try {
      await _authService.signIn(email, password);
      _setLoading(false);
      return true;
    } on FirebaseAuthException catch (error) {
      _setError(_mapAuthError(error, isSignUp: false));
      _setLoading(false);
      return false;
    } catch (_) {
      _setError('Unable to sign in right now. Try again.');
      _setLoading(false);
      return false;
    }
  }

  Future<bool> signUp(String email, String password) async {
    return register(email, password);
  }

  Future<bool> register(String email, String password) async {
    _setLoading(true);
    _setError('');
    try {
      await _authService.signUp(email, password);
      _setLoading(false);
      return true;
    } on FirebaseAuthException catch (error) {
      _setError(_mapAuthError(error, isSignUp: true));
      _setLoading(false);
      return false;
    } catch (_) {
      _setError('Unable to create account right now. Try again.');
      _setLoading(false);
      return false;
    }
  }

  Future<void> signOut() async {
    clearError();
    await _authService.signOut();
    notifyListeners();
  }

  String _mapAuthError(FirebaseAuthException error, {required bool isSignUp}) {
    switch (error.code) {
      case 'invalid-email':
        return 'Enter a valid email address.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email or password is incorrect.';
      case 'email-already-in-use':
        return 'This email is already in use.';
      case 'weak-password':
        return 'Password must have at least 6 characters.';
      case 'too-many-requests':
        return 'Too many attempts. Try again later.';
      case 'network-request-failed':
        return 'Network error. Check your connection.';
      default:
        return isSignUp
            ? 'Unable to create account right now.'
            : 'Unable to sign in right now.';
    }
  }
}
