import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:myapp/features/session/domain/push_registry.dart';

/// FCM tokens stored in Supabase (`push_tokens`); the `notify` Edge Function
/// sends the same content-free "Nova mensagem" as the Firebase backend.
class SupabasePushRegistry implements PushRegistry {
  SupabasePushRegistry(this._client, this._messaging);

  final SupabaseClient _client;
  final FirebaseMessaging _messaging;
  static const _storage = FlutterSecureStorage();
  StreamSubscription<String>? _refresh;

  Future<String> _deviceId() async {
    var id = await _storage.read(key: 'push_device_id');
    if (id == null) {
      final r = Random.secure();
      id = List.generate(20, (_) => r.nextInt(36).toRadixString(36)).join();
      await _storage.write(key: 'push_device_id', value: id);
    }
    return id;
  }

  Future<void> _save(String uid, String token) async => _client.from('push_tokens').upsert({
    'user_id': uid,
    'device_id': await _deviceId(),
    'token': token,
    'platform': Platform.isIOS ? 'ios' : 'android',
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  });

  @override
  Future<void> register(String uid) async {
    try {
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await _messaging.getToken();
      if (token != null) await _save(uid, token);
      await _refresh?.cancel();
      _refresh = _messaging.onTokenRefresh.listen((t) => _save(uid, t));
    } catch (_) {}
  }

  @override
  Future<void> unregister(String uid) async {
    await _refresh?.cancel();
    try {
      await _client.from('push_tokens').delete().eq('user_id', uid).eq('device_id', await _deviceId());
      await _messaging.deleteToken();
    } catch (_) {}
  }
}
