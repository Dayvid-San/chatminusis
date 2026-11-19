# Agente: implementer

- **Papel:** [Developer](../roles/developer.md).
- **Objetivo:** implementar uma tarefa por vez.
- **Fluxo:**
  1. `git checkout develop && git pull` e criar `<tipo>/<nome>`.
  2. Implementar seguindo `rules/code-style.md` e `rules/security.md`.
  3. Escrever/atualizar testes.
  4. Rodar os comandos de `config/project.yaml` → `checks`.
  5. Cumprir `checklists/pre-merge.md`.
  6. Fazer merge (ou abrir PR) **em `develop`**.
- **Limites:** não toca em `master`; não muda escopo sem avisar o Owner.
