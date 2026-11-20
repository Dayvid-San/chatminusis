# Regra: código

## Arquitetura
Detalhes e regras de dependência em [`docs/ARQUITETURA.md`](../../docs/ARQUITETURA.md); `test/architecture_test.dart` as confere.
- `components/`: widgets reutilizáveis que não conhecem o app. Algo que mais de um módulo usaria vai para lá.
- `lib/core/`: base compartilhada (tema, erros, utilitários); não depende de módulo.
- `lib/features/<módulo>/{domain,data,presentation}/`: `domain` é Dart puro, `data` implementa contratos, `presentation` tem telas e ViewModels.
- Um módulo só entra em outro pelo `domain`.
- Estado com `provider` (`ChangeNotifier`), rotas com `go_router`.
- UI não acessa Firebase diretamente: passa pelo ViewModel → Service/Repository.

## Convenções
- Código, nomes e comentários em **inglês**; textos exibidos ao usuário em **português (pt-BR)**.
- Seguir `analysis_options.yaml`; código formatado com `dart format`.
- Preservar o final de linha existente de cada arquivo (alguns usam CRLF).
- Widgets `const` sempre que possível; nada de I/O dentro de `build`.
- Toda feature nova tem teste (unitário de ViewModel/Service no mínimo).
- Mudanças pequenas e focadas; sem refatorações não pedidas misturadas a features.
