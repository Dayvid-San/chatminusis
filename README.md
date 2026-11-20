# Chatminusis

Chat privado para Android e iOS com **criptografia ponta a ponta** em conversas 1:1 e em grupo.

- Protocolo **MLS (RFC 9420)** via OpenMLS, em Rust (`rust/chat_crypto`), exposto ao Flutter por `packages/chat_crypto_ffi`.
- **Modelo carteiro:** o servidor (Firebase ou Supabase) só leva envelopes cifrados e **os apaga assim que todos receberam**. Não há histórico nem backup no servidor: as mensagens existem só nos aparelhos, e cada pessoa guarda ou perde as suas.
- O app não entrega as mensagens a outros apps (teclado, compartilhar, backups do sistema, área de transferência); só "Copiar mensagem", por escolha da pessoa.
- **Nada é apagado sozinho:** só a própria pessoa apaga mensagens do seu aparelho. Cada conversa pode definir um tempo de visualização: depois dele, o que você recebe fica oculto (mas guardado) e dá para ver de novo.
- Busca de pessoas apenas por **nickname exato**; verificação por número de segurança.

## Documentação
| Documento | Para quê |
|---|---|
| [`harness/`](harness/README.md) | Regras para humanos e agentes (fluxo Git: tudo vai para `develop`) |
| [`docs/PLANO_SEGURANCA_E_CHATS.md`](docs/PLANO_SEGURANCA_E_CHATS.md) | Roadmap, decisões e status de cada etapa |
| [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) | Módulos, camadas, regras de dependência, componentes reutilizáveis e a visibilidade por conversa |
| [`docs/MODELO_CARTEIRO.md`](docs/MODELO_CARTEIRO.md) | Como o servidor só leva e esquece, o que fica no aparelho e o que se perde |
| [`docs/SEGURANCA.md`](docs/SEGURANCA.md) | Modelo de ameaças, revisão, pendências e checklist de lançamento |
| [`supabase/README.md`](supabase/README.md) | Como usar o backend Supabase |

## Rodando
```bash
flutter pub get
flutter run                                    # backend Firebase (padrão)
flutter run --dart-define=BACKEND=supabase \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
```
Pré-requisitos: Flutter 3.50+, Rust (`rustup`), Android NDK (Android Studio) e Xcode (iOS).
O código Rust é compilado automaticamente no build do Flutter (cargokit).

## Testes
```bash
cargo test --manifest-path rust/chat_crypto/Cargo.toml          # núcleo criptográfico
cargo build --manifest-path packages/chat_crypto_ffi/rust/Cargo.toml && flutter test   # app (usa a lib Rust real)
(cd components && flutter test)                                   # componentes reutilizáveis
(cd firebase && npm ci && npm test)                              # regras do banco (emulador, Java 11+)
(cd functions && npm ci && npm test)                             # Cloud Functions
supabase/tests/run.sh                                            # RLS do Supabase (PostgreSQL)
```
O CI (`.github/workflows/ci.yml`) roda tudo isso em cada PR.
