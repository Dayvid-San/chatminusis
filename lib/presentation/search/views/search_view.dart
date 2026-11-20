import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/entities/user_profile.dart';
import '../view_models/search_view_model.dart';
import '../../shared_widgets/private_input.dart';

/// Find a person by their exact nickname.
class SearchView extends StatefulWidget {
  const SearchView({super.key, this.onStartConversation});

  /// Called with the found profile when the user taps "Conversar".
  final Future<void> Function(BuildContext context, UserProfile profile)? onStartConversation;

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _report(SearchViewModel vm, UserProfile p) async {
    final reason = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Denunciar @${p.nickname}'),
        content: PrivateTextField(
          controller: reason,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Motivo'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, reason.text.trim()), child: const Text('Enviar')),
        ],
      ),
    );
    reason.dispose();
    if (text == null || text.isEmpty) return;
    await vm.report(p.uid, text);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Denúncia enviada.')));
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<SearchViewModel>();
    final p = vm.result;
    return Scaffold(
      appBar: AppBar(title: const Text('Buscar pessoa')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PrivateTextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Nickname exato',
                prefixText: '@',
                border: const OutlineInputBorder(),
                errorText: vm.validation.isEmpty ? null : vm.validation,
                suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => vm.search(_query.text)),
              ),
              onSubmitted: vm.search,
            ),
            const SizedBox(height: 24),
            switch (vm.state) {
              SearchState.searching => const Center(child: CircularProgressIndicator()),
              SearchState.notFound => const Text('Ninguém com esse nickname.', textAlign: TextAlign.center),
              SearchState.rateLimited => const Text(
                'Muitas buscas seguidas. Aguarde um minuto.',
                textAlign: TextAlign.center,
              ),
              SearchState.error => const Text('Não foi possível buscar agora.', textAlign: TextAlign.center),
              SearchState.found when p != null => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: CircleAvatar(child: Text(p.displayName.characters.first.toUpperCase())),
                        title: Text(p.displayName),
                        subtitle: Text('@${p.nickname}'),
                      ),
                      if (widget.onStartConversation != null && !vm.isBlocked(p.uid))
                        ElevatedButton.icon(
                          icon: const Icon(Icons.lock_outline),
                          label: const Text('Conversar'),
                          onPressed: () => widget.onStartConversation!(context, p),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => vm.toggleBlock(p.uid),
                              child: Text(vm.isBlocked(p.uid) ? 'Desbloquear' : 'Bloquear'),
                            ),
                          ),
                          Expanded(
                            child: TextButton(onPressed: () => _report(vm, p), child: const Text('Denunciar')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              _ => const SizedBox.shrink(),
            },
          ],
        ),
      ),
    );
  }
}
