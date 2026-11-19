# Plano: Chats privados com criptografia ponta a ponta

> Documento vivo. Cada etapa deve ser concluída, revisada e testada antes da próxima.
> Status: `[ ]` pendente · `[~]` em andamento · `[x]` concluída

## 1. Objetivo

- Vários chats por usuário (lista de conversas), iniciados ao **buscar outra pessoa pelo nickname**.
- **Criptografia ponta a ponta (E2EE)**: o servidor (Firebase) guarda só dados cifrados; nem nós, como operadores, conseguimos ler mensagens.
- Alta privacidade: proteger também o aparelho, as chaves e, na medida do possível, os metadados.

### Sobre "completamente anti-hacking"

Nenhum sistema é 100% inviolável. O objetivo realista é:

1. Um ataque ao **servidor/banco** não revela conteúdo de mensagens.
2. Um ataque à **rede** (Wi-Fi público, proxy) não revela nada.
3. O vazamento de uma chave **não expõe o histórico passado nem o futuro** (forward secrecy e post-compromise security).
4. Um **servidor malicioso** não consegue se passar por outra pessoa sem que o usuário possa detectar (verificação de chaves).
5. Um **aparelho perdido/roubado** bloqueado não entrega as mensagens.

Fora de alcance (precisa ser dito ao usuário): celular com malware/root comprometido, alguém que fotografa a tela, o próprio interlocutor vazando a conversa, e metadados que o Firebase inevitavelmente vê (quem fala com quem e quando), a não ser que migremos de backend no futuro.

## 2. Estado atual (nov/2026)

- Flutter + Firebase Auth (e-mail/senha) + Realtime Database.
- **Uma única sala global** (`/messages`), mensagens em **texto puro**.
- Nome de exibição escolhível (`displayName` do Firebase Auth).
- Sem regras de segurança versionadas no repositório, sem App Check.

## 3. Decisões técnicas propostas

| Tema | Proposta | Motivo |
|---|---|---|
| Protocolo 1:1 | **Signal Protocol** (X3DH/PQXDH + Double Ratchet) | Padrão da indústria (Signal, WhatsApp); forward secrecy e post-compromise security |
| Pós-quântico | **PQXDH** (X25519 + ML-KEM) quando a biblioteca suportar | Protege contra "colher agora, decifrar depois" |
| Grupos (se houver) | **MLS (RFC 9420)**, ex.: OpenMLS via `flutter_rust_bridge` | Escala melhor que Sender Keys, padrão IETF |
| Biblioteca | Avaliar: `libsignal` oficial (Rust) via FFI × `libsignal_protocol_dart` (port em Dart) | **Nunca implementar o protocolo à mão.** Checar licenças (libsignal é AGPL) e manutenção |
| Cifra simétrica | AES-256-GCM ou ChaCha20-Poly1305 (via biblioteca) | AEAD: confidencialidade + integridade |
| Chaves no aparelho | `flutter_secure_storage` (Keychain / Android Keystore, preferir hardware-backed) | Chave privada nunca sai do aparelho em claro |
| Banco local | SQLCipher (ou equivalente) com chave no Keystore | Mensagens decifradas não ficam em claro no disco |
| Backend | Manter Firebase nas primeiras etapas; reavaliar na Etapa 11 | Menor esforço agora; metadados são a limitação |

## 4. Modelo de dados alvo (Realtime Database)

```
users/{uid}
    nickname            "dayvid"          (exibido, único)
    displayName         "Dayvid"
    createdAt
nicknames/{nicknameNormalizado} -> uid    (índice de unicidade e busca)

keys/{uid}/{deviceId}
    identityKey         (pública)
    signedPreKey        { id, publicKey, signature }
    oneTimePreKeys/{id} (públicas, consumidas uma a uma)
    pqPreKey            (ML-KEM, se PQXDH)

userConversations/{uid}/{conversationId}
    peerUid, lastActivity, unread         (sem prévia de texto!)

conversations/{conversationId}
    members/{uid}: true
    createdAt

messages/{conversationId}/{messageId}
    senderUid, senderDeviceId
    ciphertext, type (prekey|normal)
    timestamp
```

Nada de `text` em claro em lugar nenhum do servidor.

---

## 5. Etapas

### Etapa 0. Modelo de ameaças e decisões `[ ]`
- [ ] Validar as decisões da seção 3 e responder as perguntas da seção 6.
- [ ] Prova de conceito: compilar a biblioteca Signal escolhida em Android, iOS (e Web, se necessário) e trocar uma mensagem entre dois processos.
- **Pronto quando:** biblioteca escolhida e rodando nas plataformas-alvo.

### Etapa 1. Endurecimento da base `[ ]`
- [ ] Versionar `database.rules.json` no repo; negar tudo por padrão, liberar só o necessário por `auth.uid`.
- [ ] Ativar **Firebase App Check** (Play Integrity / App Attest).
- [ ] Exigir **verificação de e-mail**; política de senha mais forte; limitar tentativas.
- [ ] Remover a sala global `/messages` (ou congelá-la como somente leitura até a migração).
- [ ] Remover logs com dados sensíveis; revisar `firebase_options.dart` e segredos no repo.
- **Pronto quando:** testes do Emulator Suite provam que um usuário não lê dados de outro.

### Etapa 2. Perfil e nickname único `[ ]`
- [ ] Tela de criar/editar nickname (regras: 3–20 caracteres, `a-z 0-9 _ .`, normalizado em minúsculas).
- [ ] Reserva atômica via **transação** em `nicknames/{nick}` (impede duplicados e corrida).
- [ ] Troca de nickname libera o antigo.
- [ ] Usuários existentes são obrigados a escolher nickname no próximo login.
- **Pronto quando:** dois usuários nunca conseguem o mesmo nickname, nem tentando ao mesmo tempo.

### Etapa 3. Busca de pessoas `[ ]`
- [ ] Busca por prefixo (`orderByKey().startAt(q).endAt(q + '')`) com mínimo de 3 caracteres e limite de resultados.
- [ ] Resultado mostra só nickname e nome; **nunca e-mail**.
- [ ] Opção de privacidade: "só me encontram pelo nickname exato".
- [ ] Bloquear / denunciar usuário.
- [ ] Mitigar enumeração em massa (limite de resultados + App Check; avaliar Cloud Function com rate limit).
- **Pronto quando:** é possível achar alguém pelo nickname sem expor dados além do necessário.

### Etapa 4. Múltiplas conversas (estrutura, ainda sem E2EE) `[ ]`
- [ ] Tela "Conversas" (lista) → tela da conversa; rota `/chat/:conversationId`.
- [ ] Iniciar conversa a partir da busca; `conversationId` determinístico para 1:1 (hash dos dois uids ordenados) para não duplicar.
- [ ] Regras: só membros leem/escrevem em `conversations/{id}` e `messages/{id}`.
- [ ] Refatorar `ChatService`/`ChatViewModel` para receber `conversationId`.
- **Pronto quando:** vários chats 1:1 funcionam e as regras isolam cada um.
- Observação: pode ser feita em paralelo com a Etapa 5; o texto ainda trafega em claro até a Etapa 6, então **não lançar para usuários reais** entre a 4 e a 6.

### Etapa 5. Identidade criptográfica e chaves `[ ]`
- [ ] No primeiro login de cada aparelho: gerar identity key, signed prekey e ~100 one-time prekeys.
- [ ] Privadas no Secure Storage; públicas em `keys/{uid}/{deviceId}`.
- [ ] Reposição automática de one-time prekeys quando acabarem; rotação periódica da signed prekey.
- [ ] Regras: só o dono escreve suas chaves; qualquer autenticado lê as públicas; one-time prekey consumida é removida.
- **Pronto quando:** cada aparelho tem identidade publicada e verificável.

### Etapa 6. E2EE 1:1 (X3DH + Double Ratchet) `[ ]`
- [ ] Ao abrir conversa nova: buscar prekey bundle do outro e estabelecer sessão (X3DH, ou PQXDH se disponível).
- [ ] Toda mensagem cifrada com o Double Ratchet antes do `push`; decifrada ao receber.
- [ ] O servidor recebe só `ciphertext` e metadados mínimos.
- [ ] Tratar mensagens fora de ordem, duplicadas e falhas de decifragem (mostrar "não foi possível decifrar", nunca travar).
- [ ] Testes: vetores conhecidos, sessão entre dois clientes simulados, chave comprometida não decifra mensagens antigas.
- **Pronto quando:** inspecionando o banco no console do Firebase, nenhuma mensagem é legível.

### Etapa 7. Verificação de identidade `[ ]`
- [ ] "Número de segurança" / QR code por conversa (fingerprint das identity keys dos dois lados).
- [ ] Aviso visível quando a chave do contato mudar (reinstalação ou possível ataque MITM).
- [ ] Marcar contato como "verificado".
- **Pronto quando:** um servidor que troque chaves públicas é detectável pelos usuários.

### Etapa 8. Proteção no aparelho `[ ]`
- [ ] Banco local cifrado (SQLCipher) para histórico e estado do ratchet.
- [ ] Bloqueio do app por biometria/PIN.
- [ ] `FLAG_SECURE` no Android (bloqueia print e prévia no multitarefa); equivalente no iOS.
- [ ] Mensagens temporárias (autodestruição por tempo, apagadas nos dois lados).
- [ ] Logout apaga chaves e dados locais.
- [ ] Detecção de root/jailbreak (aviso, não garantia).

### Etapa 9. Notificações sem vazamento `[ ]`
- [ ] Push (FCM) sem conteúdo: só "nova mensagem"; o app busca e decifra localmente.
- [ ] Nada de prévia de texto em `userConversations`.

### Etapa 10. Multi-dispositivo e backup (opcional) `[ ]`
- [ ] Cada aparelho tem chaves próprias; mensagens cifradas para cada aparelho do destinatário (fan-out).
- [ ] Vincular novo aparelho por QR code a partir de um aparelho já confiável.
- [ ] Backup do histórico cifrado com chave derivada de senha forte (Argon2id), opcional e desligado por padrão.

### Etapa 11. Grupos e metadados (opcional) `[ ]`
- [ ] Conversas em grupo com MLS.
- [ ] Reduzir metadados: avaliar "sealed sender", padding de tamanho de mensagem, e migração do Firebase para backend próprio.

### Etapa 12. Auditoria contínua `[ ]`
- [ ] Revisão de segurança de cada etapa (`/security-review`) antes do merge.
- [ ] Testes automatizados das regras do banco (Emulator Suite) no CI.
- [ ] Atualização e auditoria de dependências.
- [ ] Pentest externo antes de divulgar o app como "seguro".

---

## 6. Perguntas em aberto

1. **Plataformas:** só Android/iOS ou também Web? (Web limita armazenamento seguro de chaves e FFI.)
2. **Grupos** são necessários na primeira versão ou só 1:1?
3. **Multi-dispositivo:** o mesmo usuário em dois aparelhos ao mesmo tempo?
4. **Histórico ao trocar de aparelho:** aceitar perder (mais seguro) ou oferecer backup cifrado?
5. **Licença:** o app será open-source? (Define se libsignal/AGPL é viável.)
6. **Backend:** continuar no Firebase a longo prazo ou planejar servidor próprio para reduzir metadados?
7. **Busca:** por prefixo (mais prático) ou só nickname exato (mais privado)?

## 7. Ordem sugerida

`0 → 1 → 2 → 3 → 4 + 5 → 6 → 7 → 8 → 9` é o núcleo (app 1:1 seguro).
`10, 11` dependem das respostas da seção 6. `12` acontece em todas as etapas.
