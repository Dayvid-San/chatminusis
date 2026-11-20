import 'dart:convert';
import 'dart:typed_data';

import 'package:myapp/features/messaging/domain/conversation_backend.dart';
import 'package:myapp/features/security/domain/secure_store.dart';

/// Keeps this many KeyPackages published so others can start conversations.
const keyPackageTarget = 20;
const keyPackageLowWater = 8;

/// KeyPackages expire (about 90 days). Replace the whole pool well before.
const keyPackagePoolMaxAge = Duration(days: 45);

/// The reusable last-resort KeyPackage is renewed this often.
const lastResortMaxAge = Duration(days: 30);

/// Keeps the single-use KeyPackages and the last-resort one published and
/// fresh. The cryptographic work (generate and persist the private parts) is
/// done by the callbacks, which the owner runs under its own lock.
class KeyPackagePool {
  KeyPackagePool({
    required this.uid,
    required ConversationBackend backend,
    required SecureStore store,
    required DateTime Function() now,
    required Future<List<Uint8List>> Function(int count) generate,
    required Future<Uint8List> Function() generateLastResort,
  }) : _backend = backend,
       _store = store,
       _now = now,
       _generate = generate,
       _generateLastResort = generateLastResort;

  final String uid;
  final ConversationBackend _backend;
  final SecureStore _store;
  final DateTime Function() _now;
  final Future<List<Uint8List>> Function(int count) _generate;
  final Future<Uint8List> Function() _generateLastResort;

  Future<int?> _readInt(String name) async {
    final raw = await _store.read(name);
    return raw == null ? null : int.tryParse(utf8.decode(raw));
  }

  Future<void> _writeInt(String name, int value) => _store.write(name, utf8.encode('$value'));

  Future<void> ensure() async {
    final nowMs = _now().millisecondsSinceEpoch;
    final poolAt = await _readInt('kp_pool_at');
    final stale = poolAt != null && nowMs - poolAt > keyPackagePoolMaxAge.inMilliseconds;
    if (stale) await _backend.clearKeyPackages(uid); // pool and last resort: both are about to expire

    final count = stale ? 0 : await _backend.countKeyPackages(uid);
    if (count < keyPackageLowWater) {
      final kps = await _generate(keyPackageTarget - count);
      await _backend.publishKeyPackages(uid, kps);
      if (stale || poolAt == null) await _writeInt('kp_pool_at', nowMs);
    }

    final lastAt = await _readInt('last_resort_at');
    if (stale || lastAt == null || nowMs - lastAt > lastResortMaxAge.inMilliseconds) {
      final kp = await _generateLastResort();
      await _backend.publishLastResortKeyPackage(uid, kp);
      await _writeInt('last_resort_at', nowMs);
    }
  }
}
