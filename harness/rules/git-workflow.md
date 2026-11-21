# Regra: fluxo de Git

## Branches permanentes

| Branch | Função | Quem escreve |
|---|---|---|
| `master` | Produção / releases estáveis | Só merge de `develop` (ou `hotfix/*`), aprovado pelo Owner |
| `develop` | Integração. **Destino de toda feature e correção** | Merge de branches de trabalho |

## Branches de trabalho

Sempre criados **a partir de `develop` atualizado**:

```
<tipo>/<descricao-curta-em-kebab-case>
```

Exemplos: `feat/nickname-unico`, `fix/scroll-chat`, `docs/plano-e2ee`, `refactor/chat-service`.

Tipos permitidos: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `ci`, `security`, `hotfix`.

Branches gerados automaticamente por ferramentas (ex.: `ccr-*`, `claude/*`) seguem a mesma regra: o destino final é `develop`.

## Regras obrigatórias

1. **Todo trabalho concluído (feat, fix etc.) deve ser integrado em `develop`.** Nenhum trabalho fica "parado" só no branch de trabalho.
2. **Nunca** commitar direto em `master`. Commitar direto em `develop` só para ajustes triviais de configuração do harness.
3. Antes do merge: atualizar o branch com `develop`, rodar as verificações de [`../config/project.yaml`](../config/project.yaml) e cumprir [`../checklists/pre-merge.md`](../checklists/pre-merge.md).
4. Merge preferencialmente via **Pull Request para `develop`**; use `--no-ff` em merges locais para preservar o histórico da feature.
5. Uma feature = um branch = um assunto. Não misturar mudanças não relacionadas.
6. Nunca reescrever histórico (`push --force`, `rebase` de commits publicados) em `develop` ou `master`.
7. Após o merge, o branch de trabalho pode ser apagado.
8. Release: `develop` → `master` com PR, tag `vX.Y.Z` e entrada no changelog.
9. `hotfix/*` sai de `master`, volta para `master` **e** para `develop`.

## Mensagens de commit

Padrão [Conventional Commits](https://www.conventionalcommits.org/):

```
<tipo>(<escopo opcional>): <resumo no imperativo, até 72 caracteres>

<corpo opcional: o porquê da mudança>
```

Exemplo: `feat(auth): permitir escolher nome de exibição no cadastro`.
Modelo em [`../templates/commit-message.txt`](../templates/commit-message.txt).

## Fluxo resumido

```bash
git checkout develop && git pull
git checkout -b feat/minha-feature
# ... commits ...
git fetch origin && git merge origin/develop     # atualizar
# rodar verificações e checklist
git push -u origin feat/minha-feature
# abrir PR feat/minha-feature -> develop  (ou merge --no-ff local)
```
