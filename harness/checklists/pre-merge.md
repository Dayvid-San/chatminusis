# Checklist antes do merge em `develop`

- [ ] Branch criado a partir de `develop` e atualizado com ele.
- [ ] Nome do branch segue `<tipo>/<descricao>`.
- [ ] Commits seguem Conventional Commits.
- [ ] `dart format`, `flutter analyze` e `flutter test` passam (ou está registrado por que não puderam rodar).
- [ ] Testes novos/atualizados para o que mudou.
- [ ] Nenhum segredo, chave ou dado pessoal no diff.
- [ ] Nenhuma mensagem em texto puro enviada ao servidor ou a logs.
- [ ] Se tocou caminhos de `security_review_required_paths`: revisão do `security-reviewer` aprovada.
- [ ] Roadmap (`docs/PLANO_SEGURANCA_E_CHATS.md`) atualizado, se aplicável.
- [ ] Merge feito **em `develop`** (nunca em `master`).
