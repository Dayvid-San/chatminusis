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
12. **Proibido** adicionar dependências GPL, AGPL ou SSPL: o app é source-available, sem uso comercial nem forks. Só licenças permissivas (MIT, BSD, Apache-2.0, ISC, Zlib).
13. Protocolo de mensagens: **MLS (OpenMLS)** para 1:1 e grupos. Não introduzir outro protocolo sem aprovação do Owner.
14. **Nada é apagado sozinho no aparelho:** nenhuma expiração, limpeza periódica ou "mensagem temporária". Só a pessoa apaga. O que existe é ocultar mensagens recebidas depois do tempo combinado por todos os membros da conversa (padrão 7 dias); guardadas, e só o autor aprova um pedido de ver de novo.
15. **Modelo carteiro** ([`docs/MODELO_CARTEIRO.md`](../../docs/MODELO_CARTEIRO.md)): o servidor não guarda histórico nem backup; um envelope some quando todos os membros atuais confirmaram; clientes nunca apagam envelopes; o app só confirma o recebimento **depois** de gravar a mensagem no aparelho. Nada novo no servidor que persista conteúdo, nem em logs.
16. **O app não cede dados a outros apps ou serviços:** sem logs, sem compartilhar/abrir links/arquivos, sem análise de uso, sem texto selecionável; todo campo de texto (exceto e-mail/senha) usa `PrivateTextField`; a área de transferência só é escrita por `PrivateClipboard.copy`, a pedido do usuário. `test/privacy_guardrails_test.dart` precisa continuar passando.
