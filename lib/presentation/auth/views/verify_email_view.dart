import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../view_models/auth_view_model.dart';

/// Shown while the account's email is not verified. Nothing else in the app
/// (and nothing in the database rules) is reachable before verification.
class VerifyEmailView extends StatelessWidget {
  const VerifyEmailView({super.key});

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<AuthViewModel>();
    final email = vm.currentUser?.email ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Verifique seu e-mail'), centerTitle: true),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.mark_email_unread_outlined, size: 64),
                  const SizedBox(height: 16),
                  Text(
                    'Enviamos um link de confirmação para $email. Abra o link e depois toque em "Já verifiquei".',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (vm.isLoading)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    ElevatedButton(onPressed: vm.checkVerified, child: const Text('Já verifiquei')),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: vm.resendVerification, child: const Text('Reenviar e-mail')),
                    const SizedBox(height: 8),
                    TextButton(onPressed: vm.signOut, child: const Text('Sair')),
                  ],
                  if (vm.errorMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        vm.errorMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
