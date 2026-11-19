import 'dart:typed_data';

/// Encrypted-at-rest key/value storage on this device (stage 8): values are
/// sealed with a key kept in the Android Keystore / iOS Keychain.
abstract class SecureStore {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List value);
  Future<void> delete(String name);

  /// Erases everything (logout).
  Future<void> wipe();
}
