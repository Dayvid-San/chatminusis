import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'data/firebase/firebase_auth_repository.dart';
import 'data/firebase/firebase_conversation_backend.dart';
import 'data/local/file_secure_store.dart';
import 'data/firebase/firebase_profile_repository.dart';
import 'domain/entities/app_user.dart';
import 'domain/repositories/auth_repository.dart';
import 'domain/entities/user_profile.dart';
import 'domain/repositories/conversation_backend.dart';
import 'domain/repositories/profile_repository.dart';
import 'firebase_options.dart';
import 'presentation/auth/view_models/auth_view_model.dart';
import 'presentation/auth/views/login_view.dart';
import 'presentation/auth/views/register_view.dart';
import 'presentation/auth/views/verify_email_view.dart';
import 'presentation/profile/view_models/profile_view_model.dart';
import 'presentation/profile/views/nickname_view.dart';
import 'presentation/session/session_scope.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUser?>(
      stream: context.watch<AuthViewModel>().authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final user = snapshot.data;
        if (user == null) return const LoginView();
        if (!user.emailVerified) return const VerifyEmailView();
        return StreamBuilder<UserProfile?>(
          key: ValueKey(user.uid),
          stream: context.read<ProfileRepository>().watchProfile(user.uid),
          builder: (context, profile) {
            if (profile.connectionState == ConnectionState.waiting) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }
            if (profile.data == null) return NicknameView(initialName: user.displayName ?? '');
            return SessionScope(key: ValueKey('session-${user.uid}'), uid: user.uid);
          },
        );
      },
    );
  }
}

Future<void> _activateAppCheck() async {
  // Release builds prove to the backend that requests come from the genuine
  // app on a genuine device. Debug builds use the debug provider (register the
  // printed debug token in the Firebase console).
  await FirebaseAppCheck.instance.activate(
    providerAndroid: kReleaseMode ? const AndroidPlayIntegrityProvider() : const AndroidDebugProvider(),
    providerApple: kReleaseMode ? const AppleAppAttestWithDeviceCheckFallbackProvider() : const AppleDebugProvider(),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _activateAppCheck();
  await RustLib.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppTheme()),
        Provider<AuthRepository>(create: (_) => FirebaseAuthRepository(FirebaseAuth.instance)),
        Provider<ConversationBackend>(create: (_) => FirebaseConversationBackend(FirebaseDatabase.instance)),
        Provider<SecureStoreFactory>.value(value: FileSecureStore.open),
        Provider<ProfileRepository>(create: (_) => FirebaseProfileRepository(FirebaseDatabase.instance)),
        ChangeNotifierProvider<AuthViewModel>(create: (context) => AuthViewModel(context.read<AuthRepository>())),
        ChangeNotifierProvider<ProfileViewModel>(
          create: (context) => ProfileViewModel(context.read<ProfileRepository>(), context.read<AuthRepository>()),
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
      title: 'Chatminusis',
      theme: Provider.of<AppTheme>(context).getTheme(),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

final GoRouter _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const AuthGate()),
    GoRoute(path: '/register', builder: (context, state) => const RegisterView()),
  ],
);
