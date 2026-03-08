import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android: return android;
      case TargetPlatform.iOS: return ios;
      default:
        throw UnsupportedError('Plataforma não suportada');
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'SUA-CHAVE-AQUI',
    appId: 'SUA-ID-AQUI',
    messagingSenderId: '000000000',
    projectId: 'seu-projeto-id',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'SUA-CHAVE-AQUI',
    appId: 'SUA-ID-AQUI',
    messagingSenderId: '000000000',
    projectId: 'seu-projeto-id',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'SUA-CHAVE-AQUI',
    appId: 'SUA-ID-AQUI',
    messagingSenderId: '000000000',
    projectId: 'seu-projeto-id',
    iosBundleId: 'com.exemplo.myapp',
  );
}