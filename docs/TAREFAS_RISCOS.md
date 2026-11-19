# Tarefas: tratamento dos riscos em aberto

> Riscos descritos em [`SEGURANCA.md`](SEGURANCA.md), seção 4.
> Cada risco vira um branch próprio criado a partir de `develop` e, ao final, é integrado em `develop` (ver `harness/rules/git-workflow.md`).
> Status: `[ ]` pendente · `[~]` em andamento · `[x]` concluída

## Ordem sugerida

| Ordem | Risco | Severidade | Esforço | Branch |
|---|---|---|---|---|
| 1 | R7: grupo trava após 30 dias offline ✅ | Baixa | Pequeno | `fix/r7-lacuna-de-commits` |
| 2 | R4: esgotamento de KeyPackages ✅ | Média | Pequeno | `security/r4-keypackages` |
| 3 | R5: limite de busca só no app ✅ | Média | Pequeno | `security/r5-limite-busca` |
| 4 | R6: acesso ao backup | Baixa | Pequeno | `security/r6-acesso-backup` |
| 5 | R3: membro comum remove outros no MLS | Média | Grande | `security/r3-validacao-commits` |
| 6 | R8: mensagens antigas em texto puro | Info | Mínimo | (ação do Owner) |
| 7 | R9: criptografia pós-quântica | Info | Médio | `feat/r9-pos-quantico` (futuro) |

---

## R7. Grupo trava para quem fica mais de 30 dias offline `[x]`

**Problema:** a retenção apaga commits antigos; quem volta depois disso não consegue avançar de época.

### Etapa 1. Detectar a lacuna no app
- [x] No `MessagingService._drain`, identificar quando existe um commit com época maior que `local + 1` e o commit intermediário não existe mais no servidor.
- [x] Esperar um tempo curto (para não confundir com um commit apenas atrasado) antes de concluir que há lacuna.

### Etapa 2. Recuperar automaticamente
- [x] Ao confirmar a lacuna: apagar o grupo MLS local, manter o histórico e publicar um pedido de reentrada (mecanismo do R1).
- [x] Mostrar uma mensagem de sistema: "Você ficou muito tempo offline; reconectando à conversa".

### Etapa 3. Reter commits por mais tempo
- [x] Firebase (`functions/index.js`): apagar mensagens após 30 dias, mas commits só após 180 dias.
- [x] Supabase (`pg_cron`): mesma separação por `kind`.
- [x] Atualizar testes da função de retenção.

### Etapa 4. Testes e documentação
- [x] Teste de ponta a ponta: membro offline, commits apagados no servidor, membro volta e é reconectado.
- [x] Atualizar `SEGURANCA.md` (R7 → corrigido).

**Notas da implementação:**
- A lacuna é detectada comparando a época local com a do servidor (`gapDelay`, 20 s); assim também funciona quando só commits foram apagados e não sobrou nenhuma mensagem nova.
- Descoberta durante os testes: o atalho "se a chave bate, alguém já reparou" (criado no R1) ignoraria esse caso, porque o aparelho continua com a mesma chave. Foi trocado por **eleição do reparador** (menor uid entre os admins; os demais só entram depois de uma espera por posição) e por conferir que o pedido ainda está aberto antes de agir.
- Cada aparelho faz **um pedido por perda** e apaga o próprio pedido ao entrar de novo; pedidos velhos poderiam fazer o admin remover um membro saudável.

---

## R4. Esgotamento dos KeyPackages de outra pessoa `[x]`

**Problema:** qualquer usuário verificado pode consumir todos os KeyPackages de alguém e impedir que essa pessoa seja convidada.

### Etapa 1. KeyPackage de último recurso (Rust)
- [x] Gerar um KeyPackage com a extensão `last_resort` (RFC 9420) no `chat_crypto`.
- [x] Manter sua parte privada mesmo após o uso; expor na ponte Dart.
- [x] Testes no Rust: o mesmo KeyPackage de último recurso funciona para entrar em dois grupos.

### Etapa 2. Publicação e consumo
- [x] Publicar o KeyPackage de último recurso separado dos comuns (nunca é apagado).
- [x] O consumo entrega um KeyPackage comum; só usa o de último recurso quando não há mais nenhum.

### Etapa 3. Consumo apenas pelo servidor, com limite
- [x] Firebase: Cloud Function chamável `claimKeyPackage` (transação + contador por par quem pede → alvo, ex.: 10/hora); regras passam a negar a exclusão direta por terceiros.
- [x] Supabase: tabela de contadores e limite dentro de `claim_key_package`.
- [x] Recusar o consumo se o alvo bloqueou quem pede.

### Etapa 4. Testes e documentação
- [x] Testes das regras (emulador) e RLS (Postgres): exclusão direta negada, limite atingido, bloqueio respeitado.
- [x] Teste de ponta a ponta: KeyPackages comuns esgotados, convite ainda funciona pelo de último recurso.
- [x] Atualizar `SEGURANCA.md` (R4 → corrigido).

---

**Notas da implementação:**
- O OpenMLS 0.9 já tem `mark_as_last_resort()`; a chave privada de um KeyPackage de último recurso **não** é apagada ao entrar num grupo, então ele serve para vários convites (testado no Rust, inclusive depois de restaurar o estado).
- Firebase: o consumo é a Cloud Function chamável `claimKeyPackage` (exige App Check e e-mail verificado). A lógica está em `functions/core.js` e foi testada no emulador com o mesmo SDK de admin: consumo atômico, 4 clientes simultâneos sem repetir pacote, limite de 10 por hora por par, bloqueio respeitado. Nas regras, só o dono lê, grava ou apaga os próprios KeyPackages.
- Supabase: `claim_key_package` ganhou bloqueio, limite por par (com trava consultiva contra corrida) e reserva de último recurso.
- Descoberto no caminho: KeyPackages vencem em cerca de 90 dias. O app agora troca o pool inteiro a cada 45 dias e o de último recurso a cada 30, senão um convite poderia falhar para quem passa muito tempo sem abrir o app.
- Limite escolhido: 10 convites por hora para a mesma pessoa. Quem precisar de mais pode ajustar `KP_CLAIMS_PER_HOUR` e o valor na função SQL.

## R5. Limite de busca por nickname só no app `[x]`

**Problema:** um cliente modificado pode ignorar o limite e testar muitos nicknames.

### Etapa 1. Busca pelo servidor
- [x] Firebase: Cloud Function chamável `findByNickname` que retorna só nickname e nome de exibição.
- [x] Supabase: limite dentro de `find_profile_by_nickname`.

### Etapa 2. Limite por usuário
- [x] Contador por usuário (ex.: 30 buscas/hora) e bloqueio temporário ao passar do limite.
- [x] Mensagem clara no app quando o limite do servidor for atingido.

### Etapa 3. Fechar o acesso direto
- [x] Firebase: regras deixam de permitir ler `nicknames/{nick}` diretamente (só a função lê).
- [x] `users/{uid}` continua legível por uid (necessário para mostrar os nomes dos membros). Os uids são aleatórios e só se conhecem por conversas ou pela busca; listar `users` é negado. Restringir a quem compartilha conversa exigiria um índice de contatos e foi deixado de fora.

### Etapa 4. Testes e documentação
- [x] Testes: leitura direta negada, limite aplicado, busca exata continua funcionando.
- [x] Atualizar `SEGURANCA.md` (R5 → corrigido).

---

**Notas da implementação:**
- Firebase: função chamável `findByNickname` (App Check + e-mail verificado), limite de **30 buscas por hora por usuário**. Nem o dono consegue ler `nicknames/` direto. Não encontrado, "é você" e "a pessoa te bloqueou" retornam exatamente a mesma resposta (`null`), e toda busca válida conta no limite, inclusive as que não acham nada.
- Descoberto no caminho: ao reservar um nickname, o app lia `nicknames/{nick}` para saber se já tinha dono. Com a leitura fechada, esse teste agora usa a própria função de busca (que também conta no limite).
- Supabase: `find_profile_by_nickname` ganhou a mesma lógica com trava consultiva (evita corrida no contador). O contador de buscas fica numa tabela sem nenhuma política, ilegível para clientes.
- O limite do app (10/min) continua como primeira barreira; o do servidor é a que vale.

## R6. Acesso indevido ao backup `[ ]`

**Problema:** quem invade a conta consegue baixar o arquivo e a metade do servidor. Adivinhar o código de 260 bits continua inviável, então o foco é **detectar e dificultar o acesso à conta**, não contar tentativas.

### Etapa 1. Reautenticação
- [ ] Exigir login recente (senha digitada nos últimos minutos) para baixar o backup e a metade do servidor.
- [ ] Firebase: entregar a metade por Cloud Function que confere o horário do último login no token.
- [ ] Supabase: mesma verificação numa função SQL ou Edge Function.

### Etapa 2. Alerta ao dono
- [ ] Enviar e-mail a cada download do backup ("Seu backup foi baixado em …").
- [ ] Registrar data dos downloads e mostrar no app (tela de backup).

### Etapa 3. Testes e documentação
- [ ] Testes: download negado sem login recente; alerta disparado.
- [ ] Atualizar `SEGURANCA.md` (R6 → corrigido).

---

## R3. Membro comum consegue remover outros no grupo MLS `[ ]`

**Problema:** o servidor não lê o commit cifrado; um membro sem permissão pode publicar um commit que remove outros. Rejeitar só no celular trava o grupo.

### Etapa 1. Commits em formato aberto
- [ ] Configurar o OpenMLS para enviar commits como `PublicMessage` (assinados, não cifrados) e manter as mensagens cifradas.
- [ ] Confirmar que nenhum dado novo vaza (o servidor já conhece a lista de membros).
- [ ] Testes no Rust: commits legíveis pelo validador, mensagens continuam cifradas.

### Etapa 2. Validador no servidor
- [ ] Criar o validador em Rust reaproveitando o `chat_crypto` (WASM para Edge Function/Cloud Function, ou serviço em Cloud Run).
- [ ] Regras: só admin adiciona/remove; conversa 1:1 não ganha membros; o commit precisa bater com a mudança de membros declarada; assinatura do autor válida.

### Etapa 3. Escrita de commits só pelo validador
- [ ] Firebase: regras negam escrever commits direto; a função valida e faz o compare-and-set da época.
- [ ] Supabase: `publish_commit` chama o validador antes de aceitar.
- [ ] Atualizar `FirebaseConversationBackend` e `SupabaseConversationBackend`.

### Etapa 4. Defesa no celular
- [ ] Antes de aplicar um commit, o app confere as mesmas regras.
- [ ] Se um commit inválido passar, um admin recria o grupo (novo grupo MLS, todos reconvidados), aproveitando o mecanismo de reentrada.

### Etapa 5. Testes e documentação
- [ ] Testes com commits maliciosos: remoção por não admin, adição em 1:1, mudança declarada diferente da real.
- [ ] Atualizar `SEGURANCA.md` (R3 → corrigido).

---

## R8. Mensagens antigas em texto puro no banco `[ ]`

### Etapa 1. Preparar
- [ ] (Opcional) Exportar o nó `/messages` se houver algo a guardar.
- [ ] Script de remoção em `firebase/scripts/` (executado com credencial de admin).

### Etapa 2. Executar (Owner)
- [ ] Apagar o nó `/messages` no console do Firebase ou com o script.
- [ ] Remover a regra `messages` de `firebase/database.rules.json` e o teste correspondente.
- [ ] Atualizar `SEGURANCA.md` (R8 → concluído).

---

## R9. Criptografia pós-quântica `[ ]`

### Etapa 1. Acompanhar
- [ ] Acompanhar a ciphersuite híbrida (X25519 + ML-KEM) do MLS sair de rascunho e chegar a uma versão estável do OpenMLS.

### Etapa 2. Preparar o núcleo para mais de uma suíte
- [ ] Trocar a constante `CIPHERSUITE` por uma lista de suítes aceitas, com a preferida para grupos novos.
- [ ] Manter a recusa antecipada de suítes fora da lista (ver nota RUSTSEC-2026-0387 em `deny.toml`).

### Etapa 3. Migração
- [ ] Grupos novos usam a suíte pós-quântica.
- [ ] Grupos existentes migram na próxima rotação de chaves (ou são recriados).
- [ ] Testes de interoperabilidade entre versões do app.
- [ ] Atualizar `SEGURANCA.md` (R9 → concluído).
