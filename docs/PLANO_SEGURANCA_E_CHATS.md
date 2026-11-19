# Plano: Chats privados com criptografia ponta a ponta

> Documento vivo. Cada etapa deve ser concluída, revisada e testada antes da próxima, e integrada em `develop` (ver `harness/rules/git-workflow.md`).
> Status: `[ ]` pendente · `[~]` em andamento · `[x]` concluída

## 1. Objetivo

- Conversas **1:1 e em grupo**, iniciadas ao buscar outra pessoa pelo **nickname exato**.
- **Criptografia ponta a ponta (E2EE)**: o servidor guarda só dados cifrados; nem nós, como operadores, conseguimos ler mensagens.
- Alta privacidade: proteger também o aparelho, as chaves, o backup e, na medida do possível, os metadados.

### Sobre "completamente anti-hacking"

Nenhum sistema é 100% inviolável. O objetivo realista é:

1. Um ataque ao **servidor/banco** não revela conteúdo de mensagens.
2. Um ataque à **rede** (Wi-Fi público, proxy) não revela nada.
3. O vazamento de uma chave **não expõe o histórico passado nem o futuro** (forward secrecy e post-compromise security).
4. Um **servidor malicioso** não consegue se passar por outra pessoa sem que o usuário possa detectar (verificação de chaves).
5. Um **aparelho perdido/roubado** bloqueado não entrega as mensagens.
6. Um **backup roubado** é inútil sem a conta do dono **e** o código de recuperação dele.

Fora de alcance (precisa ser dito ao usuário): celular com malware/root comprometido, alguém que fotografa a tela, o próprio interlocutor vazando a conversa, e metadados que o servidor inevitavelmente vê (quem fala com quem e quando).

## 2. Decisões do Owner (19/11/2026)

| # | Pergunta | Decisão | Consequência no plano |
|---|---|---|---|
| 1 | Plataformas | **Android e iOS** (sem Web) | Podemos usar código nativo (Rust via FFI) e o Keystore/Keychain de hardware |
| 2 | Grupos | **Sim, desde o início** | Protocolo único para 1:1 e grupos: **MLS** |
| 3 | Multi-dispositivo | **Não** (um aparelho por conta) | Simplifica chaves; trocar de aparelho = restaurar backup |
| 4 | Histórico ao trocar de aparelho | **Backup cifrado que só o app abre** | Etapa 10; ver seção 3.2 sobre o limite técnico |
| 5 | Licença | **Código visível para gerar confiança, sem uso comercial e sem forks** | Licença *source-available* (não open-source) e **proibido usar dependências GPL/AGPL** (seção 3.3) |
| 6 | Backend | **Migrar para Supabase no futuro** | Camada de abstração de backend já na Etapa 1; migração na Etapa 11 |
| 7 | Busca | **Somente nickname exato** | Sem busca por prefixo; reduz enumeração de usuários |

## 3. Decisões técnicas

### 3.1 Protocolo e bibliotecas

| Tema | Decisão | Motivo |
|---|---|---|
| Protocolo (1:1 e grupos) | **MLS - Messaging Layer Security (RFC 9420)**; uma conversa 1:1 é um grupo MLS de 2 membros | Padrão IETF, forward secrecy e post-compromise security, escala para grupos, um único código para os dois casos |
| Biblioteca | **OpenMLS** (Rust, licença MIT) integrada ao Flutter via **`flutter_rust_bridge`** | Licença permissiva, compatível com a decisão 5. Alternativa de reserva: `vodozemac` (Olm/Megolm, Apache-2.0) |
| Descartados | `libsignal` (AGPL-3.0) e ports do Signal em GPL | A AGPL/GPL obrigaria a liberar o app sob a mesma licença, **permitindo forks e uso comercial**, o contrário da decisão 5 |
| Pós-quântico | Ciphersuite híbrida (X25519 + ML-KEM) quando estável no OpenMLS; até lá, X25519 + AES-256-GCM / ChaCha20-Poly1305 | Proteção contra "colher agora, decifrar depois" |
| Chaves no aparelho | `flutter_secure_storage` com Android Keystore (StrongBox quando houver) e iOS Keychain/Secure Enclave | A chave privada nunca sai do aparelho em claro |
| Banco local | SQLCipher (ou equivalente) com chave protegida pelo Keystore/Keychain | Mensagens decifradas não ficam em claro no disco |

**Regra:** nunca implementar criptografia à mão. Toda a lógica criptográfica fica na biblioteca auditada; o app só orquestra.

### 3.2 Backup "que só o app abre": o que é possível garantir

Pedido: *nenhum outro software ou recurso consegue abrir o backup, só o nosso app.*

**Limite técnico honesto:** um segredo embutido no app não protege o backup. Qualquer chave que esteja dentro do app pode ser extraída por engenharia reversa, e aí qualquer software abre o backup. Como o código vai ser público (decisão 5), isso fica ainda mais fácil. A garantia real tem que vir de **segredos que só o dono tem**.

**Desenho proposto (duas metades de chave):**

```
codigoRecuperacao  = 24 palavras / 256 bits, gerado pelo app e mostrado UMA vez ao usuário
metadeUsuario      = Argon2id(codigoRecuperacao, salt)          (fica só na cabeça/papel do usuário)
metadeServidor     = 256 bits aleatórios, guardados no backend, entregues SÓ ao dono autenticado
chaveBackup        = HKDF(metadeUsuario || metadeServidor, "chatminusis-backup-v1")
arquivoBackup      = cabeçalho de formato próprio + versão + AES-256-GCM(chaveBackup, dados)
```

Para abrir o backup é preciso, ao mesmo tempo:
1. o **arquivo** de backup;
2. **entrar na conta** do dono no nosso backend (para obter `metadeServidor`, com limite de tentativas e App Check/attestation);
3. o **código de recuperação** do dono.

Na prática: roubar só o arquivo (ou só o arquivo + o código, ou só a conta) não basta, e nem nós, operadores, conseguimos abrir (não temos o código). Usar o formato num software não oficial continua teoricamente possível **para o próprio dono**, que tem todos os segredos. Isso não é falha: é o mesmo modelo de WhatsApp e Signal.

Se o usuário perder o código de recuperação, o backup é **irrecuperável** (por desenho). O app precisa deixar isso claro.

### 3.3 Licença do repositório

- O desejado (código visível, sem uso comercial, sem forks) **não é open-source**; é *source-available*.
- Candidata principal: **PolyForm Strict 1.0.0**, que permite ler e usar para fins não comerciais, mas **proíbe modificar e redistribuir** (ou seja, proíbe forks derivados). Alternativa mais branda: PolyForm Noncommercial (permite modificar para uso não comercial).
- Atenção: pelos Termos de Serviço do GitHub, um repositório **público** pode ser "forkado" pelo botão do GitHub. A licença proíbe **usar** esse fork, mas não impede o clique. Se isso for inaceitável, a alternativa é manter o repositório privado e publicar o código para auditoria de outra forma.
- Todas as dependências precisam ter licença compatível com distribuição fechada (MIT, BSD, Apache-2.0). **Proibido GPL/AGPL/SSPL** em dependências do app.
- Recomendação: confirmar a escolha com um advogado antes de publicar. Este documento não é aconselhamento jurídico.

### 3.4 Backend (Firebase agora, Supabase depois)

- A partir da Etapa 1, a UI e os ViewModels falam com **interfaces** (`AuthRepository`, `UserRepository`, `ConversationRepository`, `MessageRepository`, `KeyRepository`, `BackupRepository`). Só a implementação muda na migração.
- Como o servidor só vê dados cifrados, migrar de backend não exige migrar criptografia; só dados opacos e regras de acesso.
- Supabase: Postgres + **Row Level Security** substitui as regras do Firebase; pode ser **auto-hospedado**, o que reduz a exposição de metadados a terceiros.
- Recomendação: avaliar migrar **antes da Etapa 4** para não escrever duas vezes as regras de acesso de conversas e grupos (decisão pendente, seção 6).

## 4. Modelo de dados alvo (lógico, vale para Firebase e Supabase)

```
users/{uid}
    nickname            "dayvid"   (único, minúsculas)
    displayName         "Dayvid"
nicknames/{nickname} -> uid        (unicidade; busca só por chave exata)

keyPackages/{uid}/{id}             KeyPackages MLS públicos (consumidos um a um)
identity/{uid}                     credencial/identity key pública

conversations/{conversationId}
    type                "direct" | "group"
    members/{uid}: role ("admin" | "member")
userConversations/{uid}/{conversationId}
    lastActivity, unread           (sem prévia de texto!)

mlsMessages/{conversationId}/{id}  Commits, Welcomes e mensagens de aplicação MLS (cifrados)
    senderUid, epoch, payload, timestamp

backupShares/{uid}                 metadeServidor do backup (só o dono lê)
```

Nada de texto, nome de grupo ou foto em claro: nome e foto de grupo vão **dentro** do estado cifrado do grupo MLS.

---

## 5. Etapas

### Etapa 0. Prova de conceito e licença `[~]`
> Resultados em [`ETAPA_0_RELATORIO.md`](ETAPA_0_RELATORIO.md).
- [x] Núcleo OpenMLS (`rust/chat_crypto`): grupos de 2 e 3, remoção, 15 testes de segurança passando.
- [x] Ponte `flutter_rust_bridge` (`packages/chat_crypto_ffi`) testada pela FFI no computador.
- [x] Núcleo compila para Android (arm64, armv7, x86_64) e iOS (arm64, simulador).
- [x] Licenças auditadas: nenhuma GPL/AGPL; `hpke-rs` em MPL-2.0 (exceção pendente de aceite).
- [ ] Rodar o teste de integração em aparelho Android e iOS (precisa de NDK/Xcode, máquina do Owner).
- [ ] Owner escolhe a licença (seção 3.3) e adicionamos o `LICENSE`.
- **Pronto quando:** PoC funciona nas duas plataformas e a licença está definida.

### Etapa 1. Endurecimento da base e abstração de backend `[x]`
- [x] Interfaces `AuthRepository` e `GlobalChatRepository` (`lib/domain`) com implementação Firebase (`lib/data/firebase`); nenhuma tela importa `firebase_*`.
- [x] Regras versionadas (`firebase/database.rules.json`), negando tudo por padrão; testes no emulador (`cd firebase && npm test`).
- [x] App Check ativado (Play Integrity / App Attest; provedor de debug em builds de desenvolvimento). **Owner:** ativar a aplicação (enforcement) no console do Firebase.
- [x] Verificação de e-mail obrigatória (tela própria + regras exigem `email_verified`); senha de 10+ caracteres com letras e números; bloqueio progressivo após 3 falhas de login.
- [x] Plataforma iOS adicionada (`com.chatminusis.app`); arquivo duplicado quebrado removido.
- [x] Sala global `/messages` congelada (somente leitura) na Etapa 4 e removida do app.
- **Pronto quando:** testes no Emulator provam que um usuário não lê dados de outro, e nenhuma tela importa `firebase_*` diretamente.

### Etapa 2. Nickname único `[x]`
- [x] Criar/editar nickname (3–20 caracteres, `a-z 0-9 _ .`, minúsculas, nomes reservados bloqueados).
- [x] Reserva atômica (update multi-caminho validado pelas regras) em `nicknames/{nick}`; trocar libera o antigo; não é possível liberar o nickname em uso.
- [x] Usuários sem nickname são levados à tela de escolha no próximo login.
- **Pronto quando:** dois usuários nunca conseguem o mesmo nickname, nem tentando ao mesmo tempo.

### Etapa 3. Busca por nickname exato `[x]`
- [x] Busca só por nickname **idêntico**; as regras impedem listar `users` ou `nicknames`.
- [x] Resultado mostra só nickname e nome de exibição; nunca e-mail.
- [x] Limite de 10 buscas por minuto no app (+ App Check); bloquear/desbloquear (privado) e denunciar (somente escrita).
- Limitação conhecida: um cliente modificado pode ignorar o limite do app. Para limite no servidor, mover a busca para uma Cloud Function (avaliar na Etapa 11).
- **Pronto quando:** não há como listar usuários sem saber o nickname exato.

### Etapa 4. Conversas e grupos `[x]`
- [x] Tela "Conversas" → conversa; iniciar 1:1 pela busca; criar grupo, adicionar/remover membros, renomear (só admins), sair.
- [x] Regras: só membros leem; só admins alteram membros; conversa 1:1 não ganha membros; bloqueio impede ser incluído (27 testes no emulador).
- [x] Sala global em texto puro congelada e removida do app.

### Etapa 5. Identidade e KeyPackages MLS `[x]`
- [x] Identidade gerada no primeiro login; estado MLS completo salvo cifrado (AES-256-GCM, chave no Keystore/Keychain).
- [x] 20 KeyPackages publicados e repostos automaticamente; consumo atômico por transação (uso único).
- [x] Regras: só o dono escreve identidade e KeyPackages; terceiros só consomem (apagam) um KeyPackage.
- Limitação conhecida: alguém pode esgotar os KeyPackages de outra pessoa (ataque de negação de serviço conhecido do MLS). Mitigação futura: KeyPackage de "último recurso" e limite por Cloud Function.

### Etapa 6. E2EE com MLS (1:1 e grupos) `[x]`
- [x] Toda conversa é um grupo MLS; servidor só recebe envelopes opacos (`mlsMessages`) e Welcomes (`welcomes`).
- [x] Commits com compare-and-set de época no servidor; o commit só é aplicado localmente depois de aceito, e perder a corrida é tratado automaticamente.
- [x] Envelopes aplicados em ordem (época, id), com tolerância a mensagens atrasadas (3 épocas) e marcação "não foi possível decifrar".
- [x] O remetente declarado ao servidor precisa bater com a assinatura MLS; título do grupo vai cifrado e só admins o mudam.
- [x] Admins removem do grupo MLS quem saiu no servidor; divergência entre servidor e grupo MLS gera alerta.
- [x] Rotação automática das próprias chaves a cada 7 dias (e manual).
- [x] Testes: 28 no núcleo Rust, 4 na ponte e 10 de ponta a ponta no serviço Dart com a biblioteca real.

### Etapa 7. Verificação de identidade `[x]`
- [x] Chave de cada contato fixada no primeiro contato (TOFU), salva no cofre local.
- [x] Número de segurança de 60 dígitos (SHA-512 iterado, simétrico) + QR code por contato.
- [x] Troca de chave gera aviso na lista, banner e mensagem de sistema em todas as conversas com a pessoa; o status volta a "não verificado".
- [x] Marcar/desmarcar como verificado.
- Leitura do QR pela câmera não foi incluída (comparar o número visualmente ou em voz alta tem a mesma segurança).

### Etapa 8. Proteção no aparelho `[x]`
- [x] Histórico e estado MLS cifrados em disco (AES-256-GCM via Rust, chave no Keystore/Keychain "somente este aparelho"). Usado no lugar do SQLCipher.
- [x] Dados do app fora dos backups do Android (`allowBackup=false` + regras de extração).
- [x] Bloqueio por biometria/PIN do aparelho ao abrir e após 30 s em segundo plano.
- [x] `FLAG_SECURE` no Android (bloqueia print, gravação e prévia); desfoque no multitarefa do iOS.
- [x] Mensagens temporárias (5 min a 7 dias), apagadas nos dois lados.
- [x] Sair apaga chaves e histórico do aparelho (com aviso).
- [x] Aviso em aparelhos com root/jailbreak (o controle real no servidor é o App Check).
- O iOS não permite bloquear prints; o app apenas oculta o conteúdo no multitarefa.

### Etapa 9. Notificações sem vazamento `[x]`
- [x] Token FCM por aparelho em `pushTokens/{uid}` (privado; removido ao sair).
- [x] Cloud Function `notifyNewEnvelope`: avisa os outros membros com texto genérico "Nova mensagem", sem remetente, conversa ou conteúdo; commits não notificam; tokens mortos são apagados.
- [x] Cloud Function `pruneOldEnvelopes`: apaga envelopes e Welcomes com mais de 30 dias.
- **Owner:** fazer o deploy (`firebase deploy --only functions,database`), habilitar o plano Blaze, enviar a chave APNs ao Firebase e ativar Push Notifications + Background Modes no Xcode.
- Consequência da retenção: quem ficar mais de 30 dias sem abrir o app perde commits e precisa ser adicionado de novo aos grupos.

### Etapa 10. Backup cifrado `[x]`
- [x] Desenho da seção 3.2: código de recuperação de 260 bits (52 caracteres) + metade de 32 bytes no servidor + Argon2id (64 MiB, 3 passes) + HKDF + AES-256-GCM, com parâmetros autenticados (sem downgrade).
- [x] Código mostrado uma vez; o usuário confirma digitando o último bloco.
- [x] Arquivo guardado no nosso backend (`backups/{uid}`), legível só pelo dono verificado; metade do servidor em `backupShares/{uid}`.
- [x] Restauração em aparelho novo: login + código → estado e histórico restaurados, mesma identidade (contatos não veem troca de chave).
- [x] Depois de restaurar: KeyPackages antigos apagados e substituídos, e chaves renovadas em todas as conversas antes de qualquer envio (evita reutilizar chaves/nonces do aparelho antigo).
- [x] Backup automático a cada 24 h, manual, troca de código e desativação (apaga a cópia do servidor).
- O código fica salvo no cofre local do aparelho para permitir o backup automático (mesma proteção das chaves).
- Limite de tentativas na entrega da metade do servidor: depende da autenticação da conta + App Check. Para um limite real por tentativas, mover a entrega para uma Cloud Function (pendência).

### Etapa 11. Migração para Supabase `[ ]`
- [ ] Implementar os repositórios com Supabase (Postgres + RLS + Realtime + Storage).
- [ ] Testes de RLS equivalentes aos das regras do Firebase.
- [ ] Migrar dados opacos (usuários, nicknames, KeyPackages, conversas, mensagens cifradas).
- [ ] Avaliar Supabase auto-hospedado para reduzir metadados com terceiros.

### Etapa 12. Auditoria contínua `[ ]`
- [ ] Revisão do `security-reviewer` em toda etapa sensível.
- [ ] Testes de regras/RLS no CI; auditoria de dependências e licenças.
- [ ] Pentest externo antes de divulgar o app como seguro.

---

## 6. Pendências do Owner

1. **Licença:** PolyForm Strict (sem modificações) ou PolyForm Noncommercial (permite modificar para uso não comercial)? Repositório público (aceitando o botão de fork do GitHub) ou privado?
2. **Supabase:** migrar já, antes da Etapa 4 (evita refazer regras de conversas/grupos), ou só na Etapa 11?
3. **Backup:** onde guardar o arquivo cifrado: no nosso backend, ou no Google Drive / iCloud do usuário?
4. **Tamanho máximo de grupo** (ex.: 256 membros)?

## 7. Ordem

`0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10`, com `11` (Supabase) podendo ser antecipada para antes da `4` conforme a pendência 2. `12` acontece em todas as etapas.
