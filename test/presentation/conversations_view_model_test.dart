import 'dart:io';

import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/features/messaging/domain/conversation_backend.dart';
import 'package:myapp/features/messaging/domain/messaging_service.dart';
import 'package:myapp/features/messaging/presentation/conversations_view_model.dart';

import '../fakes/fake_profile_repository.dart';
import '../fakes/memory_conversation_backend.dart';
import '../fakes/memory_secure_store.dart';

void main() {
  setUpAll(() async {
    final ext = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open('packages/chat_crypto_ffi/rust/target/debug/libchat_crypto_ffi.$ext'),
    );
  });

  test('titles, names and friendly errors', () async {
    final server = MemoryConversationBackend();
    final profiles = FakeProfileRepository();
    await profiles.claimNickname(uid: 'alice', nickname: 'alice', displayName: 'Alice');
    await profiles.claimNickname(uid: 'bob', nickname: 'bob', displayName: 'Bob');
    final alice = MessagingService(backend: server, store: MemorySecureStore(), uid: 'alice');
    final bob = MessagingService(backend: server, store: MemorySecureStore(), uid: 'bob');
    await alice.start();
    await bob.start();
    final vm = ConversationsViewModel(alice, profiles);

    final id = await alice.startDirect('bob');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final c = vm.byId(id)!;
    vm.nameOf('bob');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(vm.titleOf(c), 'Bob');
    expect(vm.nameOf('alice'), 'Você');

    final error = await vm.run(() => alice.startDirect('ninguem'));
    expect(error, contains('ainda não abriu o app'));
    expect(await vm.run(() => alice.createGroup('G', [])), 'Escolha pelo menos uma pessoa.');
    expect(await vm.run(() => throw const RateLimitedException()), contains('Muitas tentativas'));

    vm.dispose();
    await alice.dispose();
    await bob.dispose();
  });
}
