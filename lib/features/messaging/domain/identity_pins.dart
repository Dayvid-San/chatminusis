import 'dart:convert';

import 'package:myapp/features/security/domain/secure_store.dart';

/// Trust state of a contact's identity key on this device.
enum KeyStatus {
  /// Never seen in any conversation.
  unknown,

  /// Pinned on first sight (trust on first use), not verified in person.
  pinned,

  /// Safety number confirmed by the user.
  verified,

  /// Differs from the pinned key: reinstall, new phone, or an attack.
  changed,
}

/// What [IdentityPins.observe] found.
enum PinObservation { unchanged, pinned, changed }

class _Pin {
  _Pin({required this.key});

  String key;
  String? pendingKey;
  bool verified = false;

  Map<String, Object?> toJson() => {'k': key, 'p': pendingKey, 'v': verified};

  factory _Pin.fromJson(Map<String, Object?> j) => _Pin(key: j['k'] as String)
    ..pendingKey = j['p'] as String?
    ..verified = j['v'] as bool? ?? false;
}

/// Pins each contact's signature key the first time it is seen (trust on first
/// use) and flags any later change until the user verifies it.
class IdentityPins {
  IdentityPins(this._store);

  final SecureStore _store;
  final Map<String, _Pin> _pins = {};

  Future<void> load() async {
    final raw = await _store.read('pins');
    if (raw == null) return;
    (jsonDecode(utf8.decode(raw)) as Map<String, Object?>).forEach((uid, v) {
      _pins[uid] = _Pin.fromJson((v as Map).cast<String, Object?>());
    });
  }

  Future<void> save() =>
      _store.write('pins', utf8.encode(jsonEncode({for (final e in _pins.entries) e.key: e.value.toJson()})));

  /// Registers [signatureKey] (base64) seen for [who]. In memory only: call
  /// [save] after a batch of observations.
  PinObservation observe(String who, String signatureKey) {
    final pin = _pins[who];
    if (pin == null) {
      _pins[who] = _Pin(key: signatureKey);
      return PinObservation.pinned;
    }
    if (pin.key != signatureKey && pin.pendingKey != signatureKey) {
      pin
        ..pendingKey = signatureKey
        ..verified = false;
      return PinObservation.changed;
    }
    return PinObservation.unchanged;
  }

  KeyStatus statusOf(String who) {
    final pin = _pins[who];
    if (pin == null) return KeyStatus.unknown;
    if (pin.pendingKey != null) return KeyStatus.changed;
    return pin.verified ? KeyStatus.verified : KeyStatus.pinned;
  }

  /// The key in use for [who] (the new one if it changed), base64; null if unseen.
  String? currentKey(String who) {
    final pin = _pins[who];
    return pin == null ? null : pin.pendingKey ?? pin.key;
  }

  /// The user compared safety numbers: trust the current key (accepting a
  /// change, if there was one). In memory only: call [save] afterwards.
  bool markVerified(String who, {bool verified = true}) {
    final pin = _pins[who];
    if (pin == null) return false;
    if (pin.pendingKey != null) {
      pin
        ..key = pin.pendingKey!
        ..pendingKey = null;
    }
    pin.verified = verified;
    return true;
  }
}
