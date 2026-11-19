# chat_crypto

Núcleo de criptografia ponta a ponta do app. Toda conversa (1:1 ou grupo) é um grupo **MLS (RFC 9420)**,
implementado pela biblioteca **OpenMLS** (MIT). O servidor só recebe blobs opacos: KeyPackages, Commits,
Welcomes e mensagens cifradas.

- Ciphersuite única: `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`; KeyPackages e grupos de outra suíte são recusados.
- Mensagens com padding em blocos de 64 bytes (esconde o tamanho exato).
- Estado em memória nesta fase (persistência cifrada: Etapas 5 e 8 do roadmap).

```bash
cargo test          # 15 testes de propriedades de segurança (tests/poc.rs)
cargo deny check    # licenças e vulnerabilidades (config em /deny.toml)
```
