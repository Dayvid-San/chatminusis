# Modelo "carteiro": o servidor leva, o aparelho guarda

> Decisão do Owner (20/11/2026): **cada pessoa é responsável por guardar ou perder as próprias mensagens.**
> O servidor só leva blocos cifrados e não deixa vestígios. Só o app, no aparelho, acessa as mensagens, e ele não
> as entrega a outros apps ou recursos, a não ser que a pessoa decida copiar uma mensagem.

## 1. A regra em três frases

1. **Em trânsito**, a mensagem é um bloco cifrado que o servidor não consegue ler.
2. **Entregue a todos, o servidor a apaga.** Ninguém, nem quem enviou, consegue apagá-la antes disso.
3. **No aparelho**, ela fica cifrada no cofre do app, fora de qualquer backup do sistema, e só sai se a pessoa tocar em "Copiar mensagem". **Só a própria pessoa apaga** o que está no seu aparelho; o app não apaga nada sozinho.

## 2. O que o servidor guarda

| O quê | Para quê | Até quando | Conteúdo legível? |
|---|---|---|---|
| Envelope de mensagem ou de troca de chaves | Levar ao destinatário que está offline | **Até todos os membros atuais (menos quem enviou) confirmarem o recebimento.** Rede de segurança: 7 dias | Não: cifrado de ponta a ponta |
| Welcome (convite cifrado) | Entrar numa conversa | Até o convidado processar. Rede de segurança: 7 dias | Não |
| Quem é membro de cada conversa, papéis e "época" de chaves | Saber a quem entregar e quem pode trocar chaves | Enquanto a conversa existir | Sim (metadado) |
| Perfil: nickname e nome de exibição | Busca por nickname exato | Enquanto a conta existir | Sim (público por desenho) |
| Chaves públicas e KeyPackages | Adicionar alguém que está offline | Até serem usados, ou renovados | Sim (são públicos) |
| Token de notificação | Avisar "Nova mensagem" | Até sair da conta | Sim |

**O servidor nunca guarda:** texto de mensagem, nome de grupo, histórico, anexos, **backups** (removidos), chaves privadas.

Depois que todos receberam, não resta nada: nem o envelope, nem as confirmações, nem registro de quando foi lida.

## 3. A vida de uma mensagem

```
Alice envia  →  cifra no aparelho  →  servidor guarda o envelope, anotando quem ainda não recebeu
Bob (online) →  recebe, decifra, GRAVA no cofre do aparelho  →  só então confirma ("recebi")
Carol (offline) →  o envelope espera por ela
Carol volta  →  recebe, grava, confirma  →  todos confirmaram: o servidor APAGA o envelope
```

Casos que importam:

| Situação | O que acontece |
|---|---|
| O aparelho não consegue gravar (disco cheio) | **Não confirma.** O envelope fica no servidor e é entregue de novo quando o app reabrir. *(testado: confirmar antes de gravar faz o teste falhar)* |
| O app fecha depois de gravar e antes de confirmar | Na reabertura recebe de novo, reconhece que já tem (sem duplicar) e só confirma. |
| Alguém sai do grupo | Deixa de ser esperado: o que só dependia dessa pessoa é apagado na hora. |
| Entra um membro novo | Não recebe o que veio antes (não conseguiria decifrar), e esse passado não o segura. |
| Ninguém busca por 7 dias | O envelope é descartado. Quem passou mais que isso offline **perde essas mensagens** e volta ao grupo por reentrada. |
| Um membro mal-intencionado tenta apagar uma mensagem antes de os outros receberem | Não consegue: clientes não têm permissão de apagar. Quem apaga é uma função do servidor, depois de todos confirmarem. |

> **Dependência importante (Firebase):** quem apaga é uma Cloud Function (`onAck`, `onMemberGone`). Se ela não estiver
> publicada, nada é apagado na entrega e as mensagens cifradas ficam até a rede de segurança de **7 dias**. No Supabase
> isso é feito dentro do próprio banco (`ack_envelope`), sem depender de função externa.

## 4. O que fica no aparelho, e como não sai de lá

| Porta de saída | Proteção | Garantido por |
|---|---|---|
| Arquivos do app | Cifrados (AES-256-GCM); chave no Keystore/Keychain "somente deste aparelho" | testes do cofre |
| Backup do Android (nuvem e transferência) | `allowBackup=false` + regras excluindo tudo | teste de guarda |
| Backup do iOS (iCloud e computador) | Pasta do cofre marcada como excluída do backup | teste de guarda* |
| Capturas, gravação, prévia no multitarefa | Android: `FLAG_SECURE`. iOS: tela desfocada ao sair do app | teste de guarda* |
| Teclado (sugestões, correção, aprendizado) | Desligados em todos os campos de mensagem, grupo, nickname e busca | teste de widget |
| Corretor ortográfico e preenchimento automático | Desligados nesses campos | teste de widget |
| Menu de seleção ("Compartilhar", "Traduzir", "Pesquisar") | Só Recortar, Copiar, Colar e Selecionar tudo. Android: removida a permissão de listar outros apps | testes de widget e de guarda |
| Selecionar texto das mensagens | Não existe texto selecionável | teste de guarda |
| Registros (logs) | O app não escreve nenhum | teste de guarda |
| Área de transferência | Nunca lida. Escrita **só** em "Copiar mensagem" (segurar a mensagem). iOS: só neste aparelho, expira em 1 min. Android 13+: marcada como sensível | testes de guarda e de comportamento |
| Compartilhar, abrir links ou arquivos, análise de uso, relatórios de erro | Nenhuma dependência desse tipo | teste de guarda |
| Notificações | Sempre "Nova mensagem", sem remetente nem texto | testes das funções |
| Pastas públicas, cache, downloads | Nunca usadas | teste de guarda |

\* Verifica o código-fonte, não o comportamento num aparelho: o código nativo (Kotlin e Swift) **não foi compilado nem executado** no ambiente de desenvolvimento.

Os testes de guarda (`test/privacy_guardrails_test.dart`) leem o próprio código do projeto. Se alguém reintroduzir um
vazamento (um `print`, um botão de compartilhar, o bloco `<queries>` que vem no modelo padrão do Flutter), o teste
falha. Foram validados reintroduzindo três vazamentos de propósito.

## 5. O que cada pessoa perde, e quando

| Situação | Consequência |
|---|---|
| Perdeu ou trocou de celular | **O histórico se perde.** Não há backup em lugar nenhum. As conversas continuam: o aparelho novo pede para voltar e um admin o convida de novo |
| Reinstalou o app | Igual: o histórico sai junto com o app |
| Saiu da conta | O app avisa e apaga chaves e histórico do aparelho |
| Ficou mais de 7 dias offline | Perde as mensagens enviadas nesse intervalo que ninguém retirou do servidor |
| Apagou uma mensagem ou limpou a conversa | Some **só deste aparelho**. A outra pessoa guarda a cópia dela |
| Saiu do grupo ou foi removido | A conversa fica na lista como encerrada, com o histórico, até **você** apagá-la |
| O tempo passou | **Nada é apagado sozinho.** O app nunca remove uma mensagem por conta própria |
| Janela de visibilidade da conversa | As mensagens que você recebe ficam **ocultas** depois do tempo definido; continuam guardadas e você pode ver de novo tocando nelas (ver [`ARQUITETURA.md`](ARQUITETURA.md) §5) |

Não existe "recuperar": nem o servidor, nem os desenvolvedores têm cópia.

## 6. Limites reais (o que este modelo **não** resolve)

- **Metadados.** Enquanto a conversa existe, o servidor sabe quem participa, quando alguém envia (até a entrega) e o tamanho aproximado. Ele não guarda um registro duradouro de quem falou com quem, mas o momento da entrega é visível enquanto acontece.
- **A outra pessoa.** Quem recebe pode copiar, fotografar a tela ou repassar. Nenhum desenho técnico impede isso.
- **iOS não bloqueia capturas de tela.** O app só desfoca a prévia do multitarefa. No Android as capturas são bloqueadas.
- **Serviços de acessibilidade (Android).** Um leitor de tela malicioso instalado pelo usuário pode ler o que aparece. O bloqueio de capturas não impede isso.
- **Aparelho com root/jailbreak ou malware.** O app avisa, mas não consegue se defender de quem controla o aparelho.
- **Área de transferência no Android.** Depois de copiar, a mensagem fica lá até outra cópia (o iOS expira sozinho). Outros apps podem lê-la no Android antigo; a partir do 13 a prévia é ocultada.
- **Teclado de terceiros.** Os campos pedem ao teclado que não aprenda nem sugira, mas é o teclado quem decide obedecer. Teclados confiáveis (os do sistema) obedecem.
- **Backups e registros do provedor.** Serviços gerenciados podem manter cópias do banco (por exemplo, backups diários do Supabase ou exportações do Firebase). Elas podem conter envelopes que estavam **em trânsito** naquele momento (sempre cifrados, nunca texto). Se isso importar, desative backups e exportações automáticas do banco, ou use o Supabase em servidor próprio.
- **Quem opera o servidor** poderia, em tese, se passar por admin (a regra "só admin troca chaves" confia no papel registrado). Por isso existe o número de segurança para verificar contatos.
- **Código nativo não verificado:** a cópia privada, a exclusão do backup do iOS e o bloqueio de capturas dependem de código Kotlin/Swift que precisa ser compilado e testado em aparelhos reais.

## 7. Para o Owner: o que falta fazer

- [ ] Publicar regras e funções: `firebase deploy --only database,functions` (as funções `onAck` e `onMemberGone` são o que apaga o que foi entregue).
- [ ] **Apagar o que o servidor ainda tem de antes deste modelo** (mensagens antigas em texto puro e backups): `cd functions && node scripts/purge-legacy-data.js --project <id>` (só simula) e depois com `--confirm`.
- [ ] Supabase: aplicar as migrações (`supabase db push`); a `20261125` apaga as tabelas de backup e a `20261126` ativa o carteiro.
- [ ] Compilar e testar em **Android e iOS reais**: cópia privada, exclusão do backup, desfoque no multitarefa, bloqueio de capturas.
- [ ] Conferir no iOS (Ajustes → [seu nome] → iCloud → Gerenciar armazenamento) que o app não aparece com dados no backup.
