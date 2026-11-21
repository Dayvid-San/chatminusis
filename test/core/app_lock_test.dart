import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/features/security/data/app_lock.dart';

class FakeAuth implements DeviceAuthenticator {
  bool supported = true;
  bool succeed = true;
  int prompts = 0;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return succeed;
  }
}

class MemFlags implements FlagStore {
  final Map<String, bool> values = {};

  @override
  Future<bool> get(String key) async => values[key] ?? false;

  @override
  Future<void> set(String key, bool value) async => values[key] = value;
}

void main() {
  late FakeAuth auth;
  late MemFlags flags;
  late DateTime now;
  AppLock make() => AppLock(authenticator: auth, flags: flags, clock: () => now);

  setUp(() {
    auth = FakeAuth();
    flags = MemFlags();
    now = DateTime(2026, 11, 19);
  });

  test('disabled by default: never locks', () async {
    final lock = make();
    await lock.load();
    lock.onBackground();
    now = now.add(const Duration(hours: 1));
    lock.onForeground();
    expect(lock.locked, isFalse);
  });

  test('enabling requires authentication and a device lock', () async {
    final lock = make();
    await lock.load();
    auth.succeed = false;
    expect(await lock.setEnabled(true), isFalse);
    expect(lock.enabled, isFalse);
    auth
      ..succeed = true
      ..supported = false;
    expect(await lock.setEnabled(true), isFalse);
    auth.supported = true;
    expect(await lock.setEnabled(true), isTrue);
    expect(flags.values['app_lock_enabled'], isTrue);
  });

  test('locks on cold start and after the grace period, not before', () async {
    flags.values['app_lock_enabled'] = true;
    final lock = make();
    await lock.load();
    expect(lock.locked, isTrue, reason: 'cold start');
    expect(await lock.unlock(), isTrue);
    expect(lock.locked, isFalse);

    lock.onBackground();
    now = now.add(const Duration(seconds: 10));
    lock.onForeground();
    expect(lock.locked, isFalse, reason: 'within grace');

    lock.onBackground();
    now = now.add(const Duration(seconds: 31));
    lock.onForeground();
    expect(lock.locked, isTrue);

    auth.succeed = false;
    expect(await lock.unlock(), isFalse);
    expect(lock.locked, isTrue);
  });
}
