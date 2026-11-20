import 'package:flutter/foundation.dart';
import 'package:flutter_jailbreak_detection/flutter_jailbreak_detection.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Device authentication (biometrics or the device PIN/pattern).
abstract class DeviceAuthenticator {
  Future<bool> isSupported();
  Future<bool> authenticate(String reason);
}

class LocalDeviceAuthenticator implements DeviceAuthenticator {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isSupported() => _auth.isDeviceSupported();

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }
}

/// Small persisted flags.
abstract class FlagStore {
  Future<bool> get(String key);
  Future<void> set(String key, bool value);
}

class SecureFlagStore implements FlagStore {
  static const _storage = FlutterSecureStorage();

  @override
  Future<bool> get(String key) async => await _storage.read(key: key) == '1';

  @override
  Future<void> set(String key, bool value) => _storage.write(key: key, value: value ? '1' : '0');
}

/// App lock: when enabled, the app asks for biometrics/device PIN on start and
/// whenever it returns after [grace] in the background.
class AppLock extends ChangeNotifier {
  AppLock({
    required DeviceAuthenticator authenticator,
    required FlagStore flags,
    DateTime Function()? clock,
    this.grace = const Duration(seconds: 30),
  }) : _auth = authenticator,
       _flags = flags,
       _now = clock ?? DateTime.now;

  static const _key = 'app_lock_enabled';

  final DeviceAuthenticator _auth;
  final FlagStore _flags;
  final DateTime Function() _now;
  final Duration grace;

  bool _enabled = false;
  bool _locked = false;
  DateTime? _backgroundedAt;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked;

  Future<void> load() async {
    _enabled = await _flags.get(_key);
    _locked = _enabled; // cold start
    notifyListeners();
  }

  /// Enabling requires a successful authentication first.
  Future<bool> setEnabled(bool value) async {
    if (value) {
      if (!await _auth.isSupported()) return false;
      if (!await _auth.authenticate('Confirme para ativar o bloqueio do app')) return false;
    }
    _enabled = value;
    _locked = false;
    await _flags.set(_key, value);
    notifyListeners();
    return true;
  }

  void onBackground() => _backgroundedAt ??= _now();

  void onForeground() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (_enabled && since != null && _now().difference(since) >= grace) {
      _locked = true;
      notifyListeners();
    }
  }

  Future<bool> unlock() async {
    if (!locked) return true;
    final ok = await _auth.authenticate('Desbloqueie para ver suas conversas');
    if (ok) {
      _locked = false;
      notifyListeners();
    }
    return ok;
  }
}

/// Root/jailbreak hint. Not a guarantee: App Check attestation is the real
/// server-side control.
Future<bool> deviceLooksCompromised() async {
  try {
    return await FlutterJailbreakDetection.jailbroken;
  } catch (_) {
    return false;
  }
}
