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

- Cada conversa tem uma janela (ou nenhuma). Ela vale para **todos** os participantes e é definida por quem administra
  (na conversa 1:1, qualquer um dos dois). Viaja cifrada, como o título do grupo, e é reenviada a quem entra depois.
  O receptor confere o papel: um membro comum que forje o pacote é ignorado.
- Vale **só para o que o receptor recebe**. As próprias mensagens nunca ficam ocultas, nem os avisos do sistema.
- O relógio de uma mensagem recebida começa na **primeira vez que ela aparece na tela**, não na chegada. Acabado o tempo, a
  mensagem fica **oculta**: some o texto da tela e da prévia na lista. Ela continua guardada no aparelho.
- "**Ver de novo**": tocar na mensagem oculta a mostra por mais uma janela. É local: não pede nada ao remetente.
- Ligar a janela numa conversa que já tem mensagens dá a elas uma janela contada a partir daquele momento. Desligar mostra tudo.
- Limite honesto: ocultar é **proteção de tela**, não destruição. Quem tem o aparelho desbloqueado e o app aberto pode tocar
  em "ver de novo". O texto continua no cofre cifrado, e a outra pessoa pode ter copiado ou fotografado antes.

## 6. Como acrescentar algo

- Tela ou widget que mais de um módulo usaria → `components/`, sem importar nada do app.
- Regra de negócio nova → `domain/` do módulo certo, com teste sem Flutter quando possível.
- Acesso a Firebase/Supabase/arquivo → `data/`, atrás de uma interface do `domain/`.
- Rodar `flutter test` (inclui o teste de arquitetura) e `bash` das verificações do CI antes de integrar em `develop`.
