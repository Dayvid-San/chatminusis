# Segurança do Chatminusis

Revisão feita na Etapa 12 (19/11/2026) sobre todo o código das Etapas 0 a 11. Este documento é a referência
para o agente `security-reviewer` (`harness/agents/security-reviewer.md`) e deve ser atualizado a cada mudança sensível.

## 1. Arquitetura em uma página

```
 Aparelho (Android/iOS)                                 Servidor (Firebase ou Supabase)
 ┌──────────────────────────────────────────┐           ┌───────────────────────────────────┐
 │ UI Flutter                               │           │ Auth (e-mail verificado)          │
 │  └ MessagingService (Dart)               │  blobs    │ conversations: membros + época    │
 │     ├ chat_crypto (Rust, OpenMLS/RFC9420)│ ───────▶  │ mlsMessages / welcomes (opacos)   │
 │     └ cofre local AES-256-GCM            │ ◀───────  │ keyPackages / identity (públicos) │
 │        chave no Keystore/Keychain        │           │ backups (cifrados) + metade chave │
 └──────────────────────────────────────────┘           │ Regras/RLS: quem lê e escreve     │
                                                        │ Functions: push genérico, limpeza │
                                                        └───────────────────────────────────┘
```

- Toda conversa (1:1 ou grupo) é um grupo **MLS**: forward secrecy, post-compromise security, assinatura de cada mensagem.
- O servidor guarda apenas: quem é membro de qual conversa, a época do grupo, blobs cifrados, chaves públicas.
- Texto, nome de grupo e histórico **nunca** saem do aparelho em claro.

## 2. Modelo de ameaças

| Atacante | Consegue | Não consegue |
|---|---|---|
| Invasor do banco / operador do servidor | Ver metadados (quem fala com quem, quando, tamanho aproximado); apagar ou atrasar mensagens; negar serviço | Ler conteúdo, nomes de grupo ou histórico; forjar mensagens; abrir backups (falta o código) |
| Servidor malicioso trocando chaves (MITM) | Tentar inserir um aparelho falso numa conversa | Fazer isso sem disparar "a chave mudou" e alterar o número de segurança |
| Rede (Wi-Fi público) | Nada além do servidor | Ler ou alterar tráfego (TLS + E2EE) |
| Ladrão do celular bloqueado | Nada, com bloqueio do app ligado | Ler o cofre (chave presa ao Keystore/Keychain e ao desbloqueio do aparelho) |
| Membro de um grupo | Ler o que é enviado enquanto for membro | Ler mensagens anteriores à entrada ou posteriores à remoção |
| Quem rouba o arquivo de backup | Nada | Abrir sem o código **e** sem entrar na conta |
| Malware com root no aparelho | Tudo o que o usuário vê | (fora do alcance de qualquer app) |

## 3. O que foi verificado

| Área | Verificação | Testes |
|---|---|---|
| Núcleo MLS (Rust) | Sigilo, adulteração, replay, membro removido, entrada tardia, apagamento de chaves antigas, corrida de commits, persistência, uso único de KeyPackage, ciphersuite única | 28 (`cargo test`) |
| Ponte Dart↔Rust | Mesmas operações chamadas do Dart pela FFI | 4 |
| Serviço de mensagens | Fluxos completos com a biblioteca real: 1:1, grupos, admin, rotação concorrente, reinício, saída, temporárias, verificação de chaves, reentrada sem backup | 14 |
| Backup | Duas metades, conta errada, código errado, sem a parte do servidor, restauração com rotação | 3 |
| Regras Firebase | Isolamento por usuário, compare-and-set de época, admin, bloqueio, remetente, KeyPackages, backups, push, reentrada | 30 (emulador) |
| RLS Supabase | As mesmas garantias + perfis não listáveis | 55 asserções (PostgreSQL 16) |
| Cloud Functions | Push sem conteúdo, tokens inválidos, retenção | 4 |
| Dependências | Licenças (sem GPL/AGPL) e vulnerabilidades | `cargo deny`, varredura pub |

## 4. Achados da revisão

| # | Severidade | Achado | Status |
|---|---|---|---|
| R1 | Alta | Reinstalar sem backup deixava a pessoa presa para sempre em "aguardando troca de chaves" (e impedia nova conversa 1:1 com o mesmo contato). | **Corrigido**: pedido de reentrada; admin (ou o outro membro na 1:1) re-convida o novo aparelho. |
| R2 | Alta | Restaurar um backup poderia reutilizar chaves/nonces que o aparelho antigo já tinha usado. | **Corrigido** na Etapa 10: rotação obrigatória antes de enviar + troca de KeyPackages. |
| R3 | Média | Um membro comum pode publicar um commit MLS que remove outro membro (o servidor não lê o conteúdo do commit). O efeito é só perturbação (ele já lia o grupo), e o app mostra "membros divergem". | **Aberto.** Correção: commits em `PublicMessage` validados no servidor (Cloud Function/função SQL) ou política de rejeição no cliente. |
| R4 | Média | Qualquer usuário verificado pode consumir todos os KeyPackages de outro (negação de serviço conhecida do MLS). | **Corrigido**: KeyPackage de último recurso, consumo só pelo servidor com limite por par e respeito a bloqueios. |
| R5 | Média | Limite de buscas por nickname só no app. | **Aberto.** Mover a busca para Cloud Function/função SQL com limite por usuário. |
| R6 | Baixa | A metade do backup no servidor não tem limite de tentativas próprio (depende da senha da conta e do App Check). | **Aberto.** Entregar via função com contador. |
| R7 | Baixa | Quem fica mais de 30 dias offline perde commits apagados pela retenção e o grupo trava. | **Corrigido**: lacuna de commits detectada e o aparelho pede reentrada sozinho; commits ficam 180 dias no servidor (mensagens, 30). |
| R8 | Info | Mensagens antigas da sala global em texto puro (`/messages`) continuam no banco. | **Owner**: apagar o nó `/messages`. |
| R9 | Info | Ciphersuite pós-quântica ainda é rascunho no OpenMLS. | Reavaliar antes do lançamento. |

> Plano de tratamento dos achados abertos, dividido em etapas: [`TAREFAS_RISCOS.md`](TAREFAS_RISCOS.md).

## 5. Antes de lançar: checklist do Owner

- [ ] Rodar o app em Android e iOS reais (`flutter run`) e o teste de integração do pacote (`packages/chat_crypto_ffi/example`).
- [ ] Firebase: publicar regras e funções (`firebase deploy --only database,functions`), plano Blaze, **ativar a aplicação do App Check**.
- [ ] Firebase Auth: exigir verificação de e-mail e política de senha no console.
- [ ] iOS: chave APNs no Firebase; capacidades Push Notifications e Background Modes no Xcode.
- [ ] Apagar o nó legado `/messages` (R8).
- [ ] Definir a licença do repositório (roadmap, seção 3.3) e adicionar `LICENSE`.
- [ ] Corrigir R3 a R5 ou aceitar o risco formalmente.
- [ ] Contratar auditoria/pentest externo antes de divulgar o app como seguro.
- [ ] Assinatura de release do Android (hoje usa a chave de debug) e `applicationId` definitivo.

## 6. Como manter

- Toda mudança em `rust/`, `packages/chat_crypto_ffi/rust/`, `lib/domain/services/`, regras, RLS ou funções passa pelo `security-reviewer`.
- O CI (`.github/workflows/ci.yml`) roda todas as verificações acima em cada PR para `develop` e `master`.
- Dependências novas: `cargo deny check` e checagem de licença; nada GPL/AGPL/SSPL.
