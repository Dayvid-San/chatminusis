import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/presentation/auth/view_models/auth_view_model.dart';

import '../fakes/fake_auth_repository.dart';

void main() {
  late FakeAuthRepository repo;
  late DateTime now;
  late AuthViewModel vm;

  setUp(() {
    repo = FakeAuthRepository();
    now = DateTime(2026, 11, 19, 12);
    vm = AuthViewModel(repo, clock: () => now);
  });

  test('new password policy', () {
    expect(validateNewPassword('curta1'), isNotNull);
    expect(validateNewPassword('somenteletras'), isNotNull);
    expect(validateNewPassword('1234567890'), isNotNull);
    expect(validateNewPassword('senhaboa123'), isNull);
  });

  test('register rejects weak password without calling backend', () async {
    expect(await vm.register(email: 'a@b.com', password: 'fraca', displayName: 'A'), isFalse);
    expect(repo.user, isNull);
    expect(vm.errorMessage, contains('10 caracteres'));
  });

  test('register sends verification email and user starts unverified', () async {
    expect(await vm.register(email: 'a@b.com', password: 'senhaboa123', displayName: 'Ana'), isTrue);
    expect(repo.verificationEmails, 1);
    expect(vm.currentUser!.emailVerified, isFalse);
    expect(vm.displayName, 'Ana');
  });

  test('checkVerified refreshes the token once verified', () async {
    await vm.register(email: 'a@b.com', password: 'senhaboa123', displayName: 'Ana');
    expect(await vm.checkVerified(), isFalse);
    expect(vm.errorMessage, isNotEmpty);
    repo.verifyOnReload = true;
    expect(await vm.checkVerified(), isTrue);
    expect(repo.tokenRefreshes, 1);
  });

  test('repeated failed sign-ins trigger a growing lockout', () async {
    for (var i = 0; i < AuthViewModel.freeAttempts; i++) {
      expect(await vm.signIn('a@b.com', 'errada'), isFalse);
    }
    expect(vm.lockoutRemaining, const Duration(seconds: 5));

    // While locked, even the right password is not sent to the backend.
    expect(await vm.signIn('a@b.com', repo.password), isFalse);
    expect(repo.user, isNull);
    expect(vm.errorMessage, contains('Aguarde'));

    now = now.add(const Duration(seconds: 6));
    expect(await vm.signIn('a@b.com', 'errada'), isFalse);
    expect(vm.lockoutRemaining, const Duration(seconds: 10));

    now = now.add(const Duration(seconds: 11));
    expect(await vm.signIn('a@b.com', repo.password), isTrue);
    expect(vm.lockoutRemaining, Duration.zero);
  });

  test('display name validation', () async {
    await vm.signIn('a@b.com', repo.password);
    expect(await vm.updateDisplayName('   '), isFalse);
    expect(await vm.updateDisplayName('x' * 31), isFalse);
    expect(await vm.updateDisplayName('Novo Nome'), isTrue);
    expect(vm.displayName, 'Novo Nome');
  });

  test('reauthentication confirms the password and counts wrong ones as failures', () async {
    await vm.signIn('a@b.com', repo.password);
    expect(await vm.reauthenticate('errada'), isFalse);
    expect(vm.errorMessage, contains('incorretos'));
    expect(await vm.reauthenticate(repo.password), isTrue);
    expect(repo.reauths, 1);
  });
}
