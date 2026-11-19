import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/repositories/secure_store.dart';

/// Files sealed with AES-256-GCM. The 32-byte key lives in the Android
/// Keystore / iOS Keychain (this device only, never backed up to the cloud).
class FileSecureStore implements SecureStore {
  FileSecureStore._(this._dir, this._key, this._keyName, this._keychain);

  static const _keychainOptions = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final Directory _dir;
  final Uint8List _key;
  final String _keyName;
  final FlutterSecureStorage _keychain;

  /// Opens (creating if needed) the store of [uid].
  static Future<FileSecureStore> open(String uid) async {
    const keychain = _keychainOptions;
    final keyName = 'vault_key_$uid';
    var encoded = await keychain.read(key: keyName);
    if (encoded == null) {
      encoded = base64Encode(randomBytes(len: 32));
      await keychain.write(key: keyName, value: encoded);
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/vault/${base64Url.encode(utf8.encode(uid))}');
    await dir.create(recursive: true);
    return FileSecureStore._(dir, base64Decode(encoded), keyName, keychain);
  }

  File _file(String name) => File('${_dir.path}/${base64Url.encode(utf8.encode(name))}');

  @override
  Future<Uint8List?> read(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    return vaultOpen(key: _key, context: utf8.encode(name), sealed: await f.readAsBytes());
  }

  @override
  Future<void> write(String name, Uint8List value) async {
    final sealed = await vaultSeal(key: _key, context: utf8.encode(name), plaintext: value);
    final tmp = File('${_file(name).path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(_file(name).path); // atomic replace
  }

  @override
  Future<void> delete(String name) async {
    final f = _file(name);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<List<String>> names() async {
    if (!await _dir.exists()) return [];
    final out = <String>[];
    await for (final f in _dir.list()) {
      final base = f.uri.pathSegments.last;
      if (base.endsWith('.tmp')) continue;
      try {
        out.add(utf8.decode(base64Url.decode(base)));
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<void> wipe() async {
    if (await _dir.exists()) await _dir.delete(recursive: true);
    await _keychain.delete(key: _keyName);
  }
}
