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
    } catch (e) {
      _setError('Failed to sign in. Check your credentials.');
      _setLoading(false);
      return false;
    }
  }

  Future<bool> signUp(String email, String password) async {
    _setLoading(true);
    _setError('');
    try {
      await _authService.signUp(email, password);
      _setLoading(false);
      return true;
    } catch (e) {
      _setError('Failed to create account.');
      _setLoading(false);
      return false;
    }
  }

  Future<void> signOut() async {
    await _authService.signOut();
    notifyListeners();
  }
}