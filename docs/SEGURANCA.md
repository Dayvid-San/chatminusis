# Segurança do Chatminusis

Revisão feita na Etapa 12 (19/11/2026) e atualizada em 20/11/2026 para o **modelo carteiro**
([`MODELO_CARTEIRO.md`](MODELO_CARTEIRO.md)): o servidor só leva envelopes cifrados e os apaga após a entrega; as mensagens existem
só nos aparelhos. Este documento é a referência para o agente `security-reviewer` (`harness/agents/security-reviewer.md`) e deve
ser atualizado a cada mudança sensível.

## 1. Arquitetura em uma página

```
 Aparelho (Android/iOS)                                 Servidor (Firebase ou Supabase)
 ┌──────────────────────────────────────────┐           ┌───────────────────────────────────┐
 │ UI Flutter                               │           │ Auth (e-mail verificado)          │
 │  └ MessagingService (Dart)               │  blobs    │ conversations: membros + época    │
 │     ├ chat_crypto (Rust, OpenMLS/RFC9420)│ ───────▶  │ mlsMessages / welcomes (opacos)   │
 │     └ cofre local AES-256-GCM            │ ◀───────  │ keyPackages / identity (públicos) │
 │        chave no Keystore/Keychain        │           │ (envelopes: só até a entrega)     │
 └──────────────────────────────────────────┘           │ Regras/RLS: quem lê e escreve     │
                                                        │ Functions: push genérico, limpeza │
                                                        └───────────────────────────────────┘
```

- Toda conversa (1:1 ou grupo) é um grupo **MLS**: forward secrecy, post-compromise security, assinatura de cada mensagem.
- O servidor guarda apenas: quem é membro de qual conversa, a época do grupo, chaves públicas e, **só até serem entregues**, blobs cifrados.
- **Não há backup nem histórico no servidor.** Perdeu o aparelho, perdeu as mensagens.
- Texto, nome de grupo e histórico **nunca** saem do aparelho em claro, e o app só os entrega a outro lugar se a pessoa tocar em "Copiar mensagem".

## 2. Modelo de ameaças

| Atacante | Consegue | Não consegue |
|---|---|---|
| Invasor do banco / operador do servidor | Ver metadados (quem fala com quem, quando, tamanho aproximado); apagar ou atrasar mensagens; negar serviço | Ler conteúdo ou nomes de grupo; forjar mensagens; **recuperar mensagens já entregues** (não há cópia: o carteiro apaga) |
| Servidor malicioso trocando chaves (MITM) | Tentar inserir um aparelho falso numa conversa | Fazer isso sem disparar "a chave mudou" e alterar o número de segurança |
| Rede (Wi-Fi público) | Nada além do servidor | Ler ou alterar tráfego (TLS + E2EE) |
| Ladrão do celular bloqueado | Nada, com bloqueio do app ligado | Ler o cofre (chave presa ao Keystore/Keychain e ao desbloqueio do aparelho) |
| Membro de um grupo | Ler o que é enviado enquanto for membro | Ler mensagens anteriores à entrada ou posteriores à remoção |
| Outro app no mesmo aparelho | Nada do que o app guarda | Ler o cofre, receber texto por menu de compartilhar, teclado que aprende, backup do sistema ou área de transferência (só "Copiar mensagem" escreve nela) |
| Membro mal-intencionado | Deixar de enviar; copiar o que ele mesmo recebeu | **Apagar do servidor** uma mensagem antes de os outros a receberem |
| Malware com root no aparelho | Tudo o que o usuário vê | (fora do alcance de qualquer app) |

## 3. O que foi verificado

| Área | Verificação | Testes |
|---|---|---|
| Núcleo MLS (Rust) | Sigilo, adulteração, replay, membro removido, entrada tardia, apagamento de chaves antigas, corrida de commits, persistência, uso único de KeyPackage, ciphersuite única | 41 (`cargo test`, inclui a suíte híbrida de rascunho só nos testes) |
| Ponte Dart↔Rust | Mesmas operações chamadas do Dart pela FFI | 3 |
| Serviço de mensagens | Fluxos completos com a biblioteca real: 1:1, grupos, admin, rotação concorrente, reinício, saída, temporárias, verificação de chaves, reentrada, **carteiro** (esquece o entregue, espera o offline, só confirma depois de gravar), apagar histórico | 33 |
| Guardas de privacidade | Lêem o código do projeto: sem logs, uma única escrita na área de transferência, sem compartilhar/análise, manifest e plist travados | 16 |
| Entrada e cópia privadas | Teclado/corretor/autofill desligados, menu de seleção reduzido, copiar só pelo menu da mensagem | 10 |
| Regras Firebase | Isolamento por usuário, compare-and-set de época, admin, bloqueio, remetente, KeyPackages, push, reentrada, **confirmações de entrega**, ninguém apaga envelope, servidor recusa guardar backup | 42 (emulador) |
| RLS Supabase | As mesmas garantias + perfis não listáveis + **carteiro** (lista de pendentes calculada no servidor, confirmação, saída de membro, nada apagável à mão) | 102 asserções (PostgreSQL 16) |
| Cloud Functions | Push sem conteúdo, tokens inválidos, retenção de 7 dias, **carteiro** (apagar quando todos confirmaram, saída de membro, remetente), script de limpeza | 30 (unitários + emulador) |
| Dependências | Licenças (sem GPL/AGPL) e vulnerabilidades | `cargo deny`, varredura pub |

## 4. Achados da revisão

| # | Severidade | Achado | Status |
|---|---|---|---|
| R1 | Alta | Reinstalar sem backup deixava a pessoa presa para sempre em "aguardando troca de chaves" (e impedia nova conversa 1:1 com o mesmo contato). | **Corrigido**: pedido de reentrada; admin (ou o outro membro na 1:1) re-convida o novo aparelho. |
| R2 | Alta | Restaurar um backup poderia reutilizar chaves/nonces que o aparelho antigo já tinha usado. | **Obsoleto**: o backup foi removido (modelo carteiro), então não há restauração. |
| R3 | Média | Um membro comum pode publicar um commit MLS que remove outro membro (o servidor não lê o conteúdo do commit). O efeito é só perturbação (ele já lia o grupo), e o app mostra "membros divergem". | **Corrigido** com outro desenho: só admins publicam commits (regra do servidor), membros comuns renovam chaves por proposta, e o app recusa conteúdo que não combine com o tipo do envelope. Risco residual: um admin malicioso e a dependência de um admin online. |
| R4 | Média | Qualquer usuário verificado pode consumir todos os KeyPackages de outro (negação de serviço conhecida do MLS). | **Corrigido**: KeyPackage de último recurso, consumo só pelo servidor com limite por par e respeito a bloqueios. |
| R5 | Média | Limite de buscas por nickname só no app. | **Corrigido**: busca feita pelo servidor, 30 por hora por usuário, leitura direta de `nicknames/` fechada. |
| R6 | Baixa | A metade do backup no servidor não tem limite de tentativas próprio. | **Obsoleto**: não há backup no servidor. O que existir de produção deve ser apagado com `functions/scripts/purge-legacy-data.js`. |
| R7 | Baixa | Quem fica offline além da retenção perde commits e o grupo trava. | **Corrigido**: lacuna de commits detectada e o aparelho pede reentrada sozinho. No modelo carteiro a retenção é de **7 dias para todos os tipos** (antes 30/180): quem passa mais que isso offline também perde as mensagens desse intervalo. |
| R8 | Info | Mensagens antigas da sala global em texto puro (`/messages`) continuam no banco. | **Acesso fechado** (regra removida, nenhum cliente lê o nó). **Falta apagar os dados**, ação sua: `functions/scripts/delete-legacy-messages.js` (simula por padrão). |
| R9 | Info | Ciphersuite pós-quântica ainda é rascunho no OpenMLS. | **Núcleo preparado** para várias suítes e testado com a suíte híbrida real; a migração aguarda o padrão sair de rascunho (critérios em `TAREFAS_RISCOS.md`). |

> Plano de tratamento dos achados abertos, dividido em etapas: [`TAREFAS_RISCOS.md`](TAREFAS_RISCOS.md).

## 5. Antes de lançar: checklist do Owner

- [ ] Rodar o app em Android e iOS reais (`flutter run`) e o teste de integração do pacote (`packages/chat_crypto_ffi/example`).
- [ ] Firebase: publicar regras e funções (`firebase deploy --only database,functions`), plano Blaze, **ativar a aplicação do App Check**.
- [ ] Firebase Auth: exigir verificação de e-mail e política de senha no console.
- [ ] iOS: chave APNs no Firebase; capacidades Push Notifications e Background Modes no Xcode.
- [ ] Apagar o que o servidor ainda tem de antes do modelo carteiro (R8): mensagens antigas em texto puro e backups. O acesso já está fechado; use `functions/scripts/purge-legacy-data.js` (só simula sem `--confirm`).
- [ ] Publicar as funções `onAck` e `onMemberGone` (é o que apaga o entregue no Firebase) e aplicar as migrações do Supabase.
- [ ] Compilar e testar em aparelhos reais o código nativo novo (cópia privada, exclusão do backup do iOS, bloqueio de capturas): não foi compilado no ambiente de desenvolvimento.
- [ ] Desativar backups e exportações automáticas do banco no provedor, se envelopes em trânsito nelas forem um problema.
- [ ] Definir a licença do repositório (roadmap, seção 3.3) e adicionar `LICENSE`.
- [ ] Corrigir R3 a R5 ou aceitar o risco formalmente.
- [ ] Contratar auditoria/pentest externo antes de divulgar o app como seguro.
- [ ] Assinatura de release do Android (hoje usa a chave de debug) e `applicationId` definitivo.

## 6. Como manter

- Toda mudança em `rust/`, `packages/chat_crypto_ffi/rust/`, `lib/features/messaging/domain/`, regras, RLS ou funções passa pelo `security-reviewer`.
- O CI (`.github/workflows/ci.yml`) roda todas as verificações acima em cada PR para `develop` e `master`.
- Dependências novas: `cargo deny check` e checagem de licença; nada GPL/AGPL/SSPL.
