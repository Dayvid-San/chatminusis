/// Nickname rules shared by UI, repositories and (mirrored) database rules.
abstract final class Nickname {
  static final _pattern = RegExp(r'^[a-z0-9_.]{3,20}$');
  static const _reserved = {'admin', 'administrador', 'suporte', 'support', 'chatminusis', 'root', 'sistema', 'system'};

  /// Lowercase, trimmed and without a leading '@'.
  static String normalize(String input) {
    var s = input.trim().toLowerCase();
    if (s.startsWith('@')) s = s.substring(1);
    return s;
  }

  /// Returns an error message, or null when valid. Expects a normalized value.
  static String? validate(String nickname) {
    if (nickname.length < 3 || nickname.length > 20) return 'Use de 3 a 20 caracteres.';
    if (!_pattern.hasMatch(nickname)) return 'Use apenas letras minúsculas, números, "_" e ".".';
    if (nickname.startsWith('.') || nickname.endsWith('.') || nickname.contains('..')) {
      return 'O ponto não pode ficar no início, no fim ou repetido.';
    }
    if (_reserved.contains(nickname)) return 'Este nickname é reservado.';
    return null;
  }
}
