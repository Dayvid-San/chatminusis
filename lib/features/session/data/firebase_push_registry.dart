import 'dart:async';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:myapp/features/session/domain/push_registry.dart';

/// Stores this device's FCM token under `pushTokens/{uid}/{deviceId}`.
/// The server only ever sends a generic "Nova mensagem": no sender, no
/// conversation, no content (see functions/index.js).
class FirebasePushRegistry implements PushRegistry {
  FirebasePushRegistry(this._db, this._messaging);

  final FirebaseDatabase _db;
  final FirebaseMessaging _messaging;
  static const _storage = FlutterSecureStorage();
  StreamSubscription<String>? _refresh;

  Future<String> _deviceId() async {
    var id = await _storage.read(key: 'push_device_id');
    if (id == null) {
      id = _db.ref().push().key!;
      await _storage.write(key: 'push_device_id', value: id);
    }
    return id;
  }

  Future<void> _save(String uid, String token) async {
    await _db.ref('pushTokens/$uid/${await _deviceId()}').set({
      'token': token,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'updatedAt': ServerValue.timestamp,
    });
  }

  @override
  Future<void> register(String uid) async {
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await _messaging.getToken();
      if (token != null) await _save(uid, token);
      await _refresh?.cancel();
      _refresh = _messaging.onTokenRefresh.listen((t) => _save(uid, t));
    } catch (_) {
      // Push is best-effort: messages still arrive while the app is open.
    }
  }

  @override
  Future<void> unregister(String uid) async {
    await _refresh?.cancel();
    try {
      await _db.ref('pushTokens/$uid/${await _deviceId()}').remove();
      await _messaging.deleteToken();
    } catch (_) {}
  }
}
