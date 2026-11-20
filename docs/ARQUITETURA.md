# Arquitetura do app

O código é dividido por **responsabilidade**. Cada parte tem um lugar, uma função e regras de quem pode depender de quem.
As regras são conferidas por `test/architecture_test.dart`: se uma delas for quebrada, o teste falha.

## 1. Visão geral

```
chatminusis/
├── components/            Pacote Flutter reutilizável (chatminusis_components). Não conhece o app.
├── lib/
│   ├── main.dart          Raiz de composição: escolhe o backend e liga as peças.
│   ├── core/              Base compartilhada (tema, erros, nickname). Não depende de nenhum módulo.
│   └── features/          Um diretório por funcionalidade (módulo).
│       ├── auth/          Entrar, cadastrar, verificar e-mail.
│       ├── profile/       Perfil e nickname.
│       ├── search/        Buscar pessoas pelo nickname exato.
│       ├── messaging/     Conversas, mensagens, grupos, criptografia (MLS), visibilidade.
│       ├── security/      Cofre local, bloqueio do app, ajustes de privacidade.
│       └── session/       Ciclo da sessão: liga login, cofre, mensagens e notificações.
├── rust/chat_crypto/      Núcleo MLS (OpenMLS).
├── packages/chat_crypto_ffi/   Ponte Dart↔Rust.
├── firebase/ supabase/ functions/   Servidores ("carteiros") e seus testes.
└── harness/ docs/         Regras do projeto e documentação.
```

Dentro de cada módulo há até três camadas:

| Camada | O que contém | Pode usar |
|---|---|---|
| `domain/` | Entidades, contratos (interfaces) e regras. Dart puro. | `dart:`, `chat_crypto_ffi`, `core/`, o `domain/` de outros módulos |
| `data/` | Implementações dos contratos (Firebase, Supabase, arquivos, biometria). | `domain/` e SDKs de plataforma |
| `presentation/` | Telas, ViewModels (`provider`). | `domain/`, `components/`, `core/` |

## 2. Regras de dependência (testadas)

1. **`components/` não conhece o app.** Só importa Flutter e a si mesmo. Recebe texto como `String` e ações como funções.
2. **`domain/` é Dart puro:** sem Flutter, sem SDK de Firebase/Supabase, sem `data/` nem `presentation/`.
3. **`core/` não depende de módulo nenhum.**
4. **`data/` nunca importa tela.**
5. Um módulo só entra em outro **pelo `domain/`**. Exceções listadas em `knownCoupling` no teste (telas que abrem telas de
   outro módulo, e a `session`, que liga tudo). A lista só pode encolher: um acoplamento novo exige justificativa escrita lá.
6. Classes concretas de `data/` de outro módulo só são usadas pela `session` e por `main.dart`.

## 3. Pacote `components/`

Reutilizável por qualquer módulo (e, em tese, por outro app). Testes próprios em `components/test`.

| Componente | Para quê |
|---|---|
| `PrivateTextField`, `PrivateTextFormField`, `PrivateInput` | Campos que não entregam o texto a teclado, corretor, autofill nem menu de compartilhar |
| `PrivateClipboard` | Única escrita na área de transferência (cópia privada nativa) |
| `MessageBubble`, `BubbleFrame` | Balão de mensagem genérico; o menu "Copiar" é o único caminho para fora |
| `HiddenMessageBubble` | Balão no lugar de uma mensagem oculta, com "toque para ver de novo" |
| `RebuildAt` | Reconstrói um widget quando um instante passa (a mensagem some da tela sozinha) |
| `ErrorText`, `EmptyState`, `LoadingButton`, `confirmDialog`, `durationLabel` | Peças de interface comuns |

`test/privacy_guardrails_test.dart` lê também `components/lib`: a área de transferência continua sendo escrita em um
único arquivo e chamada de um único lugar.

## 4. O módulo de mensagens por dentro

`MessagingService` coordena; cada responsabilidade que pôde ser separada sem mexer no comportamento virou uma peça:

| Peça | Responsabilidade |
|---|---|
| `SerialQueue` | Executa as operações no estado MLS uma de cada vez |
| `ConversationState` / `ConversationStore` | O que o aparelho guarda de cada conversa e como grava no cofre |
| `IdentityPins` | Fixa a chave de cada contato na primeira vez (confiança no primeiro uso) e acusa mudança |
| `KeyPackagePool` | Mantém os KeyPackages publicados e renovados |
| `VisibilityPolicy` | A regra de visibilidade por conversa, sem E/S |
| `MessagingService` | Motor MLS, recebimento e confirmação de entrega, envio, administração de grupo, reentrada e reparo |

Limite conhecido: o recebimento, a reentrada e o reparo continuam na mesma classe (cerca de 1100 linhas), porque são uma
só máquina de estados que roda sob a mesma fila e compartilha o motor MLS. Separá-los exigiria um desenho novo dessa
máquina, não só mover código. Os testes de ponta a ponta (40, com a biblioteca criptográfica real) são a rede de segurança.

## 5. Nada é apagado sozinho

- O aparelho **nunca apaga uma mensagem por conta própria**: não há expiração, limpeza periódica nem "mensagem temporária".
  Só a pessoa apaga: uma mensagem, o histórico de uma conversa, ou uma conversa encerrada. Sair da conta (explícito) apaga tudo.
- Uma conversa em que a pessoa saiu ou foi removida **continua na lista**, marcada como encerrada, com o histórico. Se a
  pessoa voltar ao grupo, o histórico antigo é mantido.

### Janela de visibilidade (por conversa)

- **Padrão: 7 dias.** Cada conversa começa com essa janela. Quem recebe uma mensagem a vê por 7 dias a partir da primeira
  vez que ela aparece na tela; depois ela fica **oculta**.
- **Os membros decidem juntos.** Qualquer membro **propõe** outro tempo (ou "sempre visíveis"). A proposta só vale quando
  **todos os membros atuais aceitarem**. Uma recusa cancela a proposta e o tempo continua como estava. Sem acordo, fica em 7 dias.
  Se os membros mudam enquanto há uma proposta pendente (alguém entra ou sai), ela é descartada e precisa ser refeita.
  Quem entra depois recebe o tempo combinado de um admin, uma única vez; um aparelho que já está na conversa ignora esse aviso.
- Tudo viaja cifrado (proposta, aceite, recusa). O servidor não vê nem o tempo.
- Vale **só para o que o receptor recebe**. As próprias mensagens e os avisos do sistema nunca ficam ocultos.
- O relógio de uma mensagem recebida começa na **primeira vez que ela aparece na tela**, não na chegada. Oculta, ela some da
  tela e da prévia da lista, mas **continua guardada** no aparelho.

### Pedir para ver de novo (o remetente decide)

1. O receptor toca na mensagem oculta: o app envia, cifrado, um **pedido** ao autor. A mensagem continua oculta e mostra
   "aguardando aprovação".
2. O autor vê o pedido **dentro do app**, com o texto da própria mensagem, e escolhe **Permitir** ou **Negar** (o ícone de sino
   aparece na lista de conversas). O aviso do sistema (push) continua genérico, "Nova mensagem", sem dizer quem pediu nem o quê.
3. Se permitir, a mensagem volta **só para quem pediu**, pelo tempo da janela da conversa, e depois oculta de novo. Se negar,
   continua oculta e a pessoa pode pedir outra vez.
4. Só o **autor** da mensagem aprova: a resposta é conferida pela assinatura MLS, então outro membro não consegue se aprovar.
5. Precisa do autor online em algum momento: se ele sair da conversa ou não abrir o app, o pedido fica esperando.

- Ligar/desligar: "sempre visíveis" é uma opção que os membros podem combinar; aí nada fica oculto e não há pedidos.
- Limite honesto: ocultar é **proteção de tela**, não destruição. O texto continua no cofre cifrado, e a outra pessoa pode
  ter copiado ou fotografado antes.

## 6. Como acrescentar algo

- Tela ou widget que mais de um módulo usaria → `components/`, sem importar nada do app.
- Regra de negócio nova → `domain/` do módulo certo, com teste sem Flutter quando possível.
- Acesso a Firebase/Supabase/arquivo → `data/`, atrás de uma interface do `domain/`.
- Rodar `flutter test` (inclui o teste de arquitetura) e `bash` das verificações do CI antes de integrar em `develop`.
