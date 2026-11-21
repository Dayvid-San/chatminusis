# chat_crypto_ffi

Plugin Flutter (Android/iOS) que expõe ao Dart o núcleo de criptografia ponta a ponta do app
(`rust/chat_crypto`, MLS / RFC 9420 via OpenMLS). Gerado com `flutter_rust_bridge` 2.13.0; o build
nativo usa o cargokit (compila o Rust automaticamente no `flutter build`).

Nenhuma lógica criptográfica fica aqui: `rust/src/api/client.rs` só repassa chamadas ao núcleo.

## Uso

```dart
await RustLib.init();
final alice = ChatCryptoClient.create(identity: utf8.encode(uid));
await alice.createGroup(groupId: conversationId);
final add = await alice.addMembers(groupId: conversationId, keyPackages: [bobKeyPackage]);
// add.commit -> membros atuais; add.welcome -> novos membros
final wire = await alice.encrypt(groupId: conversationId, plaintext: utf8.encode('oi'));
final msg = await bob.process(groupId: conversationId, message: wire);
```

## Desenvolvimento

| Tarefa | Comando (a partir deste diretório) |
|---|---|
| Regenerar a ponte após mudar `rust/src/api` | `flutter_rust_bridge_codegen generate` |
| Teste no computador (Linux/macOS) | `cargo build --manifest-path rust/Cargo.toml && flutter test` |
| Teste no aparelho/emulador | `cd example && flutter test integration_test/simple_test.dart` |
| Licenças e vulnerabilidades | `cd rust && cargo deny check` |

Pré-requisitos para Android/iOS: Rust (`rustup`), Android NDK (via Android Studio) e, para iOS, macOS com Xcode.
