# Regra: código

## Arquitetura (`lib/`)
- `core/`: serviços transversais (auth, tema, utilitários, futuramente criptografia).
- `data/`: modelos, serviços de acesso ao Firebase, repositórios.
- `domain/`: entidades e contratos de repositório.
- `presentation/<feature>/`: `views/`, `view_models/`, `widgets/`.
- Estado com `provider` (`ChangeNotifier`), rotas com `go_router`.
- UI não acessa Firebase diretamente: passa pelo ViewModel → Service/Repository.

## Convenções
- Código, nomes e comentários em **inglês**; textos exibidos ao usuário em **português (pt-BR)**.
- Seguir `analysis_options.yaml`; código formatado com `dart format`.
- Preservar o final de linha existente de cada arquivo (alguns usam CRLF).
- Widgets `const` sempre que possível; nada de I/O dentro de `build`.
- Toda feature nova tem teste (unitário de ViewModel/Service no mínimo).
- Mudanças pequenas e focadas; sem refatorações não pedidas misturadas a features.
