# Harness

Regras e configurações que **todo agente de IA (Claude, Gemini etc.) e todo desenvolvedor** deve seguir neste repositório. Leia este diretório antes de qualquer alteração.

| Diretório | Conteúdo |
|---|---|
| `rules/` | Regras obrigatórias (git, segurança, código). Em caso de conflito, `rules/` vence. |
| `roles/` | Papéis e responsabilidades: quem decide, quem implementa, quem revisa. |
| `agents/` | Definição de cada agente: objetivo, papel, entradas, saídas e limites. |
| `config/` | Configuração legível por máquina (branches, tipos de commit, comandos de verificação). |
| `checklists/` | Listas de verificação usadas antes de commit e de merge. |
| `templates/` | Modelos de commit e de pull request. |

## Regra principal de fluxo

> **Todo `feat`, `fix`, `refactor`, `docs`, `test`, `chore` etc. é desenvolvido em um branch próprio e, quando concluído, é integrado (merge) no branch `develop`.**
> `master` só recebe código vindo de `develop` em uma release. Detalhes em [`rules/git-workflow.md`](rules/git-workflow.md).

## Ordem de leitura

1. [`rules/git-workflow.md`](rules/git-workflow.md)
2. [`rules/security.md`](rules/security.md)
3. [`rules/code-style.md`](rules/code-style.md)
4. O arquivo do seu papel em `roles/` e do seu agente em `agents/`
5. [`../docs/PLANO_SEGURANCA_E_CHATS.md`](../docs/PLANO_SEGURANCA_E_CHATS.md) (roadmap)
