import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/core/utils/nickname.dart';
import 'package:myapp/presentation/profile/view_models/profile_view_model.dart';
import 'package:myapp/presentation/search/view_models/search_view_model.dart';

import '../fakes/fake_auth_repository.dart';
import '../fakes/fake_profile_repository.dart';

void main() {
  group('Nickname', () {
    test('normalizes', () {
      expect(Nickname.normalize('  @Dayvid_San '), 'dayvid_san');
    });
    test('validates', () {
      expect(Nickname.validate('ok_nick.1'), isNull);
      for (final bad in ['ab', 'a' * 21, 'tem espaco', 'acentuação', '.inicio', 'fim.', 'dois..pontos', 'admin']) {
        expect(Nickname.validate(bad), isNotNull, reason: bad);
      }
    });
  });

  group('ProfileViewModel', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late ProfileViewModel vm;

    setUp(() async {
      auth = FakeAuthRepository();
      profiles = FakeProfileRepository();
      await auth.signIn(email: 'a@b.com', password: auth.password);
      vm = ProfileViewModel(profiles, auth);
    });

    test('claims a normalized nickname and syncs the auth display name', () async {
      expect(await vm.save(nickname: '@Ana_01', displayName: 'Ana'), isTrue);
      expect(profiles.nicknames['ana_01'], 'u1');
      expect(auth.user!.displayName, 'Ana');
    });

    test('reports taken nicknames', () async {
      profiles.nicknames['ocupado'] = 'other';
      expect(await vm.save(nickname: 'ocupado', displayName: 'Ana'), isFalse);
      expect(vm.error, contains('em uso'));
    });

    test('rejects invalid input before calling the backend', () async {
      expect(await vm.save(nickname: 'a', displayName: 'Ana'), isFalse);
      expect(await vm.save(nickname: 'valido', displayName: '  '), isFalse);
      expect(profiles.nicknames, isEmpty);
    });

    test('changing nickname releases the old one', () async {
      await vm.save(nickname: 'velho', displayName: 'Ana');
      await vm.save(nickname: 'novo', displayName: 'Ana');
      expect(profiles.nicknames.keys, ['novo']);
    });
  });

  group('SearchViewModel', () {
    late FakeProfileRepository profiles;
    late DateTime now;
    late SearchViewModel vm;

    setUp(() async {
      profiles = FakeProfileRepository();
      await profiles.claimNickname(uid: 'me', nickname: 'euzinho', displayName: 'Eu');
      await profiles.claimNickname(uid: 'bob', nickname: 'bob', displayName: 'Bob');
      now = DateTime(2026, 11, 19);
      vm = SearchViewModel(profiles, 'me', clock: () => now);
    });

    tearDown(() => vm.dispose());

    test('finds only exact nicknames', () async {
      await vm.search('@BOB');
      expect(vm.state, SearchState.found);
      expect(vm.result!.uid, 'bob');
      await vm.search('bo');
      expect(vm.result, isNull);
      expect(vm.validation, isNotEmpty);
      await vm.search('bobby');
      expect(vm.state, SearchState.notFound);
    });

    test('never returns yourself', () async {
      await vm.search('euzinho');
      expect(vm.state, SearchState.notFound);
    });

    test('rate limits lookups per minute', () async {
      for (var i = 0; i < SearchViewModel.maxSearchesPerMinute; i++) {
        await vm.search('bob');
      }
      await vm.search('bob');
      expect(vm.state, SearchState.rateLimited);
      expect(profiles.lookups, SearchViewModel.maxSearchesPerMinute);
      now = now.add(const Duration(minutes: 1));
      await vm.search('bob');
      expect(vm.state, SearchState.found);
    });

    test('the server limit is reported like the app limit', () async {
      profiles.serverRateLimited = true;
      await vm.search('bob');
      expect(vm.state, SearchState.rateLimited);
      profiles.serverRateLimited = false;
      await vm.search('bob');
      expect(vm.state, SearchState.found);
    });

    test('block, unblock and report', () async {
      await vm.toggleBlock('bob');
      await pumpEventQueue();
      expect(vm.isBlocked('bob'), isTrue);
      await vm.toggleBlock('bob');
      await pumpEventQueue();
      expect(vm.isBlocked('bob'), isFalse);
      await vm.report('bob', 'spam');
      expect(profiles.reports.single, ('me', 'bob', 'spam'));
    });
  });
}
