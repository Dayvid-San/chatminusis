import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:myapp/presentation/auth/view_models/auth_view_model.dart';
import 'package:myapp/presentation/auth/views/login_view.dart';
import 'package:myapp/presentation/chat/chat_room_view.dart';
import 'package:provider/provider.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'presentation/auth/views/login_view.dart';
import 'presentation/chat/views/chat_room_view.dart';
import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';

import 'core/theme/theme_provider.dart';
import 'presentation/auth/views/login_screen.dart';
import 'presentation/chat/views/chat_screen.dart';


class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final authViewModel = context.watch<AuthViewModel>();

    return StreamBuilder(
      stream: authViewModel.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return const ChatRoomView(); 
        }
        return const LoginView();
      },
    );
  }
}

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppTheme(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Flutter Firebase AI',
      theme: Provider.of<ThemeProvider>(context).getTheme(),
      routerConfig: _router,
    );
  }
}

final GoRouter _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/chat',
      builder: (context, state) => const ChatScreen(),
    ),
  ],
);
