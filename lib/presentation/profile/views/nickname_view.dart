import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/nickname.dart';
import '../../../domain/entities/user_profile.dart';
import '../view_models/profile_view_model.dart';

/// First-time nickname setup (mandatory) and later editing.
class NicknameView extends StatefulWidget {
  const NicknameView({super.key, this.current, this.initialName = ''});

  final UserProfile? current;
  final String initialName;

  @override
  State<NicknameView> createState() => _NicknameViewState();
}

class _NicknameViewState extends State<NicknameView> {
  final _formKey = GlobalKey<FormState>();
  late final _nick = TextEditingController(text: widget.current?.nickname ?? '');
  late final _name = TextEditingController(text: widget.current?.displayName ?? widget.initialName);

  @override
  void dispose() {
    _nick.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final ok = await context.read<ProfileViewModel>().save(nickname: _nick.text, displayName: _name.text);
    if (ok && mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<ProfileViewModel>();
    final editing = widget.current != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Editar perfil' : 'Escolha seu nickname'), centerTitle: true),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Outras pessoas só encontram você digitando o seu nickname exato. Seu e-mail nunca é mostrado.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _nick,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Nickname',
                        prefixText: '@',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => Nickname.validate(Nickname.normalize(v ?? '')),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _name,
                      maxLength: 30,
                      decoration: const InputDecoration(labelText: 'Nome de exibição', border: OutlineInputBorder()),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Informe um nome.' : null,
                    ),
                    const SizedBox(height: 12),
                    if (vm.isSaving)
                      const Center(child: CircularProgressIndicator())
                    else
                      ElevatedButton(onPressed: _save, child: const Text('Salvar')),
                    if (vm.error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          vm.error,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
