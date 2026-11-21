# Etapa 0: relatório da prova de conceito

Data: 19/11/2026 · Branch: `feat/poc-openmls` → `develop`

## O que foi construído

| Peça | Local | Função |
|---|---|---|
| Núcleo E2EE | `rust/chat_crypto` | Wrapper do OpenMLS 0.9.2: identidade, KeyPackages, criar grupo, adicionar/remover membros, cifrar, processar mensagens |
| Ponte Dart | `packages/chat_crypto_ffi` | Plugin Flutter (Android/iOS) gerado com `flutter_rust_bridge` 2.13.0 + cargokit |
| Política de dependências | `deny.toml` | `cargo deny`: licenças permitidas, vulnerabilidades, fontes |

O app principal **ainda não usa** o plugin. A integração acontece nas Etapas 5 e 6.

## Resultados

### Testes do núcleo (Rust): 15/15 passando

| Propriedade | Teste |
|---|---|
| Conversa 1:1 nos dois sentidos | `direct_conversation_round_trip` |
| Servidor só vê texto cifrado | `server_only_sees_ciphertext` |
| Tamanho da mensagem escondido (padding) | `padding_hides_message_length` |
| Grupo de 3 com membro entrando depois | `group_of_three_with_late_joiner` |
| Quem entra depois não lê o histórico | `late_joiner_cannot_read_history` |
| Membro removido não lê mensagens novas | `removed_member_cannot_read_new_messages` |
| Chaves de épocas antigas são apagadas (forward secrecy) | `old_epoch_keys_are_deleted` |
| Mensagem adulterada é rejeitada | `tampered_message_is_rejected` |
| Mensagem repetida (replay) é rejeitada | `replayed_message_is_rejected` |
| Quem não é membro não decifra | `outsider_cannot_decrypt` |
| KeyPackage adulterado é rejeitado | `tampered_key_package_is_rejected` |
| KeyPackage é de uso único | `key_package_is_single_use` |
| Ciphersuite estrangeira recusada antes de rodar cripto | `foreign_ciphersuite_key_package_is_rejected_early` |
| Entrar duas vezes no mesmo grupo é recusado | `joining_same_group_twice_is_rejected` |
| Erros explícitos | `errors_are_explicit` |

### Ponte Dart ↔ Rust: 2/2 passando
`flutter test` em `packages/chat_crypto_ffi` chama o Rust de verdade pela FFI (no Linux): 1:1, grupo de 3,
remoção, erros chegando ao Dart como exceções.

### Compilação para celular
| Alvo | Núcleo (`cargo check`) | Plugin completo |
|---|---|---|
| Android arm64 / armv7 / x86_64 | ✅ compila | ⏳ não testado: falta Android NDK no ambiente de CI |
| iOS arm64 / simulador | ✅ compila | ⏳ não testado: exige macOS + Xcode |

### Licenças
- Rust: 240 crates (núcleo + ponte, todas as plataformas), todas MIT/Apache/BSD/ISC/Unicode, **exceto** `hpke-rs*` (MPL-2.0), usadas sem modificação (ver abaixo).
- Dart: 81 pacotes, todos BSD/MIT/Apache.
- Nenhuma dependência GPL/AGPL/LGPL/SSPL.

## Achados e decisões

1. **MPL-2.0 (`hpke-rs`, dependência do OpenMLS).** Copyleft fraco, por arquivo: podemos usar em app
   fechado/source-available **desde que não modifiquemos esses arquivos** e mantenhamos os avisos de licença.
   Liberado como exceção nominal em `deny.toml`. **Precisa de aceite do Owner.**
2. **RUSTSEC-2026-0387** (`crypto-bigint` 0.5, variação de tempo). Afeta só as curvas P-256/P-384/secp256k1,
   que nunca usamos: o núcleo recusa KeyPackages e grupos de outra ciphersuite antes de qualquer operação.
   Ignorado com justificativa em `deny.toml`; reavaliar quando o OpenMLS atualizar.
3. **Pós-quântico.** O OpenMLS 0.9 tem suítes PQ atrás de feature de *draft* (`draft-ietf-mls-pq-ciphersuites`).
   Não usar enquanto for rascunho; reavaliar antes do lançamento.
4. **Arquivo pré-existente quebrado:** `lib/presentation/chat/views/chat_room_view.dart` (vindo do commit
   "feat: new GUI added") tem 17 erros de compilação e não é importado em lugar nenhum. Faz o
   `flutter analyze` do app falhar. Corrigir ou remover num branch `fix/` separado.

## O que falta para fechar a Etapa 0

- [ ] **Owner:** rodar o teste no aparelho/emulador (Android e iOS), com NDK e Xcode instalados:
      `cd packages/chat_crypto_ffi/example && flutter test integration_test/simple_test.dart`
- [ ] **Owner:** aceitar a exceção MPL-2.0 (achado 1).
- [ ] **Owner:** escolher a licença do repositório (roadmap, seção 3.3) para adicionarmos o `LICENSE`.
