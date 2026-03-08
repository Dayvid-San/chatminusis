import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:myapp/presentation/auth/view_models/auth_view_model.dart';
import 'package:myapp/presentation/auth/views/login_view.dart';
import 'package:myapp/presentation/chat/chat_room_view.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'core/theme/app_theme.dart';
import 'presentation/chat/views/chat_screen.dart';
import 'firebase_options.dart';
import 'package:myapp/core/services/auth_service.dart';
import 'package:myapp/presentation/auth/views/login_view.dart';


class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final authViewModel = context.watch<AuthViewModel>();

    return StreamBuilder(
      stream: authViewModel.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasData) {
          return const ChatRoomView();
        }
        return const LoginView();
      },
    );
  }
}
void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Required for Firebase
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppTheme()),
        Provider<AuthService>(
          create: (_) => AuthService(FirebaseAuth.instance),
        ),
        ChangeNotifierProvider<AuthViewModel>(
          create: (context) => AuthViewModel(context.read<AuthService>()),
        ),
      ],
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
      theme: Provider.of<AppTheme>(context).getTheme(),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

final GoRouter _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const LoginView(),
    ),
    GoRoute(
      path: '/chat',
      // Aqui estava ChatScreen(), mude para ChatRoomView()
      builder: (context, state) => const ChatRoomView(), 
    ),
  ],
);
