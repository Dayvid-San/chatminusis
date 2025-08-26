import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static const String _databaseUrl =
      'https://chatminusis-default-rtdb.firebaseio.com';

  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAiXkAneOkKOoiZ5nl79c-byFi2CefUsDo',
    appId: '1:216172016070:android:7d7dc1260d1c0389e1c2c7', // Usando ID compatível
    messagingSenderId: '216172016070',
    projectId: 'chatminusis',
    authDomain: 'chatminusis.firebaseapp.com',
    databaseURL: _databaseUrl,
    storageBucket: 'chatminusis.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAiXkAneOkKOoiZ5nl79c-byFi2CefUsDo',
    appId: '1:216172016070:android:7d7dc1260d1c0389e1c2c7',
    messagingSenderId: '216172016070',
    projectId: 'chatminusis',
    databaseURL: _databaseUrl,
    storageBucket: 'chatminusis.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAiXkAneOkKOoiZ5nl79c-byFi2CefUsDo',
    appId: '1:216172016070:android:7d7dc1260d1c0389e1c2c7',
    messagingSenderId: '216172016070',
    projectId: 'chatminusis',
    databaseURL: _databaseUrl,
    storageBucket: 'chatminusis.firebasestorage.app',
    iosBundleId: 'com.chatminusis.app',
  );
}
