import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/entities/app_user.dart';
import '../../../domain/repositories/auth_repository.dart';

/// Password rules for new accounts (stricter than the backend minimum).
String? validateNewPassword(String password) {
  if (password.length < 10) return 'A senha deve ter pelo menos 10 caracteres.';
  if (!RegExp(r'[A-Za-z]').hasMatch(password) || !RegExp(r'\d').hasMatch(password)) {
    return 'Use letras e números na senha.';
  }
  return null;
}

class AuthViewModel extends ChangeNotifier {
  AuthViewModel(this._repo, {DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final AuthRepository _repo;
  final DateTime Function() _now;

  /// Failed sign-ins tolerated before the client imposes a growing wait.
  static const freeAttempts = 3;

  bool _isLoading = false;
  String _errorMessage = '';
  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  bool get isLoading => _isLoading;
  String get errorMessage => _errorMessage;
  AppUser? get currentUser => _repo.currentUser;
  Stream<AppUser?> get authStateChanges => _repo.authStateChanges();
  String get displayName => currentUser?.visibleName ?? 'Anônimo';

  /// Remaining client-side lockout after repeated failed sign-ins.
  Duration get lockoutRemaining {
    final until = _lockedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  void clearError() {
    if (_errorMessage.isEmpty) return;
    _errorMessage = '';
    notifyListeners();
  }

  Future<bool> _run(Future<void> Function() action) async {
    _isLoading = true;
    _errorMessage = '';
    notifyListeners();
    try {
      await action();
      return true;
    } on AuthException catch (e) {
      _errorMessage = _message(e.code);
      return false;
    } catch (_) {
      _errorMessage = 'Algo deu errado. Tente novamente.';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signIn(String email, String password) async {
    final wait = lockoutRemaining;
    if (wait > Duration.zero) {
      _errorMessage = 'Muitas tentativas. Aguarde ${wait.inSeconds + 1}s.';
      notifyListeners();
      return false;
    }
    final ok = await _run(() => _repo.signIn(email: email, password: password));
    if (ok) {
      _failedAttempts = 0;
      _lockedUntil = null;
    } else {
      _failedAttempts++;
      if (_failedAttempts >= freeAttempts) {
        // 5s, 10s, 20s ... capped at 5 minutes.
        final seconds = (5 << (_failedAttempts - freeAttempts)).clamp(5, 300);
        _lockedUntil = _now().add(Duration(seconds: seconds));
      }
    }
    return ok;
  }

  Future<bool> register({required String email, required String password, required String displayName}) {
    final problem = validateNewPassword(password);
    if (problem != null) {
      _errorMessage = problem;
      notifyListeners();
      return Future.value(false);
    }
    return _run(() => _repo.signUp(email: email, password: password, displayName: displayName));
  }

  Future<bool> resendVerification() => _run(_repo.sendEmailVerification);

  /// Returns true when the email is now verified.
  Future<bool> checkVerified() async {
    var verified = false;
    await _run(() async {
      final user = await _repo.reload();
      verified = user?.emailVerified ?? false;
      if (verified) await _repo.refreshToken();
    });
    if (!verified && _errorMessage.isEmpty) {
      _errorMessage = 'E-mail ainda não verificado.';
      notifyListeners();
    }
    return verified;
  }

  Future<bool> updateDisplayName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 30) return Future.value(false);
    return _run(() => _repo.updateDisplayName(trimmed));
  }

  Future<void> signOut() async {
    clearError();
    await _repo.signOut();
    notifyListeners();
  }

  static String _message(AuthErrorCode code) => switch (code) {
    AuthErrorCode.invalidEmail => 'Informe um e-mail válido.',
    AuthErrorCode.invalidCredentials => 'E-mail ou senha incorretos.',
    AuthErrorCode.emailInUse => 'Este e-mail já está em uso.',
    AuthErrorCode.weakPassword => 'Senha fraca. Use pelo menos 10 caracteres com letras e números.',
    AuthErrorCode.tooManyRequests => 'Muitas tentativas. Tente mais tarde.',
    AuthErrorCode.network => 'Erro de rede. Verifique sua conexão.',
    AuthErrorCode.unknown => 'Não foi possível concluir agora.',
  };
}
