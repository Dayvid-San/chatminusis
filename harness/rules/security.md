# Regra: segurança e privacidade

O objetivo do app é ser um chat privado com criptografia ponta a ponta (ver `docs/PLANO_SEGURANCA_E_CHATS.md`). Estas regras não têm exceção sem aprovação explícita do Owner.

## Criptografia
1. **Nunca implementar algoritmos ou protocolos criptográficos à mão.** Usar bibliotecas auditadas (Signal Protocol, MLS, `cryptography`).
2. Só primitivas modernas: X25519/Ed25519, AES-256-GCM ou ChaCha20-Poly1305, HKDF, Argon2id. Proibido: MD5, SHA-1, ECB, RSA < 3072, chaves fixas no código.
3. Nonce/IV nunca reutilizado com a mesma chave; sempre gerado por CSPRNG.
4. Chave privada **nunca** sai do aparelho em claro e **nunca** é enviada ao servidor.

## Dados
5. Conteúdo de mensagem **nunca** é gravado em claro no servidor, em logs, em analytics, em crash reports ou em notificações push.
6. Não expor e-mail ou uid de outros usuários na UI ou em buscas.
7. Coletar o mínimo de metadados possível.

## Servidor e regras
8. Regras do Firebase versionadas no repo, negando tudo por padrão. Toda mudança de regra exige teste no Emulator Suite.
9. Nunca commitar segredos (`.env`, chaves de serviço, keystores). `firebase_options.dart` contém só identificadores públicos.

## Processo
10. Toda mudança que toque autenticação, criptografia, regras do banco ou armazenamento de chaves passa pelo agente [`security-reviewer`](../agents/security-reviewer.md) antes do merge em `develop`.
11. Novas dependências: verificar manutenção, licença e histórico de vulnerabilidades antes de adicionar.
