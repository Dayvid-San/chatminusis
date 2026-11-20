import 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'package:myapp/features/security/data/app_lock.dart';
import 'package:myapp/core/theme/app_theme.dart';
import 'package:myapp/features/auth/data/firebase_auth_repository.dart';
import 'package:myapp/features/messaging/data/firebase_conversation_backend.dart';
import 'package:myapp/features/session/data/firebase_push_registry.dart';
import 'package:myapp/features/security/data/file_secure_store.dart';
import 'package:myapp/features/auth/data/supabase_auth_repository.dart';
import 'package:myapp/features/messaging/data/supabase_conversation_backend.dart';
import 'package:myapp/features/profile/data/supabase_profile_repository.dart';
import 'package:myapp/features/session/data/supabase_push_registry.dart';
import 'package:myapp/features/profile/data/firebase_profile_repository.dart';
import 'package:myapp/features/auth/domain/app_user.dart';
import 'package:myapp/features/auth/domain/auth_repository.dart';
import 'package:myapp/features/profile/domain/user_profile.dart';
import 'package:myapp/features/messaging/domain/conversation_backend.dart';
import 'package:myapp/features/profile/domain/profile_repository.dart';
import 'package:myapp/features/session/domain/push_registry.dart';
import 'package:myapp/firebase_options.dart';
import 'package:myapp/features/auth/presentation/auth_view_model.dart';
import 'package:myapp/features/auth/presentation/login_view.dart';
import 'package:myapp/features/auth/presentation/register_view.dart';
import 'package:myapp/features/auth/presentation/verify_email_view.dart';
import 'package:myapp/features/profile/presentation/profile_view_model.dart';
import 'package:myapp/features/profile/presentation/nickname_view.dart';
import 'package:myapp/features/security/presentation/app_lock_gate.dart';
import 'package:myapp/features/session/presentation/session_scope.dart';

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

/// Backend selection at build time:
///   flutter run --dart-define=BACKEND=supabase --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
/// Firebase stays initialized in both cases (push notifications use FCM).
const _backend = String.fromEnvironment('BACKEND', defaultValue: 'firebase');
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseKey = String.fromEnvironment('SUPABASE_KEY');

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
  final appLock = AppLock(authenticator: LocalDeviceAuthenticator(), flags: SecureFlagStore());
  await appLock.load();

  final useSupabase = _backend == 'supabase';
  if (useSupabase) {
    await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseKey);
  }
  final db = FirebaseDatabase.instance;
  final sb = useSupabase ? Supabase.instance.client : null;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppTheme()),
        ChangeNotifierProvider<AppLock>.value(value: appLock),
        Provider<AuthRepository>(
          create: (_) => sb != null ? SupabaseAuthRepository(sb) : FirebaseAuthRepository(FirebaseAuth.instance),
        ),
        Provider<ProfileRepository>(
          create: (_) => sb != null ? SupabaseProfileRepository(sb) : FirebaseProfileRepository(db),
        ),
        Provider<ConversationBackend>(
          create: (_) => sb != null ? SupabaseConversationBackend(sb) : FirebaseConversationBackend(db),
        ),
        Provider<PushRegistry>(
          create: (_) => sb != null
              ? SupabasePushRegistry(sb, FirebaseMessaging.instance)
              : FirebasePushRegistry(db, FirebaseMessaging.instance),
        ),
        Provider<SecureStoreFactory>.value(value: FileSecureStore.open),
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
      builder: (context, child) => AppLockGate(child: child ?? const SizedBox.shrink()),
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
