import 'package:flutter/foundation.dart';

import '../../../core/utils/nickname.dart';
import '../../../domain/repositories/auth_repository.dart';
import '../../../domain/repositories/profile_repository.dart';

class ProfileViewModel extends ChangeNotifier {
  ProfileViewModel(this._profiles, this._auth);

  final ProfileRepository _profiles;
  final AuthRepository _auth;

  bool _isSaving = false;
  String _error = '';

  bool get isSaving => _isSaving;
  String get error => _error;

  /// Reserves the nickname and stores the display name. Returns true on success.
  Future<bool> save({required String nickname, required String displayName}) async {
    final user = _auth.currentUser;
    if (user == null) return false;
    final nick = Nickname.normalize(nickname);
    final name = displayName.trim();
    final problem =
        Nickname.validate(nick) ?? (name.isEmpty || name.length > 30 ? 'Nome deve ter de 1 a 30 caracteres.' : null);
    if (problem != null) {
      _error = problem;
      notifyListeners();
      return false;
    }
    _isSaving = true;
    _error = '';
    notifyListeners();
    try {
      await _profiles.claimNickname(uid: user.uid, nickname: nick, displayName: name);
      if (user.displayName != name) await _auth.updateDisplayName(name);
      return true;
    } on NicknameTakenException {
      _error = 'Este nickname já está em uso.';
      return false;
    } catch (_) {
      _error = 'Não foi possível salvar agora.';
      return false;
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }
}
