import 'dart:typed_data';

import 'package:myapp/features/security/domain/secure_store.dart';

class MemorySecureStore implements SecureStore {
  final Map<String, Uint8List> data = {};

  @override
  Future<Uint8List?> read(String name) async => data[name];

  @override
  Future<void> write(String name, Uint8List value) async => data[name] = Uint8List.fromList(value);

  @override
  Future<void> delete(String name) async => data.remove(name);

  @override
  Future<List<String>> names() async => data.keys.toList();

  @override
  Future<void> wipe() async => data.clear();
}
