// Guardrails for the "messages exist only inside the app" rule.
//
// These tests read the project's own source, so a change that quietly opens a
// way out (a logger, a share button, a platform default that leaks) fails the
// build instead of shipping. If one fails, the fix is to remove the leak, not
// to edit the test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

/// Dart sources of the app (not the generated bridge code), without comment lines.
Map<String, String> appSources() => {
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
    f.path: f.readAsStringSync().split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n'),
};

List<String> filesContaining(Map<String, String> sources, Pattern pattern, {Set<String> except = const {}}) => [
  for (final e in sources.entries)
    if (!except.contains(e.key) && e.value.contains(pattern)) e.key,
];

void main() {
  final sources = appSources();

  group('nothing is written anywhere else', () {
    test('the app never logs: message text can not end up in a log', () {
      for (final pattern in [RegExp(r'\bprint\('), RegExp(r'\bdebugPrint\('), 'developer.log(', 'stdout.', 'stderr.']) {
        expect(filesContaining(sources, pattern), isEmpty, reason: 'logging with $pattern');
      }
    });

    test('the clipboard is never read, and written in exactly one place (the explicit Copy)', () {
      expect(filesContaining(sources, 'Clipboard.getData'), isEmpty);
      expect(filesContaining(sources, 'Clipboard.hasStrings'), isEmpty);
      expect(filesContaining(sources, 'Clipboard.setData'), ['lib/core/security/private_clipboard.dart']);
    });

    test('the only caller of the private clipboard is the long-press menu of a message', () {
      expect(filesContaining(sources, 'PrivateClipboard.copy'), [
        'lib/presentation/chat/widgets/message_bubble_widget.dart',
      ]);
    });

    test('data goes only to the private application-support folder', () {
      for (final api in [
        'getExternalStorageDirectory',
        'getExternalStorageDirectories',
        'getExternalCacheDirectories',
        'getApplicationDocumentsDirectory',
        'getApplicationCacheDirectory',
        'getTemporaryDirectory',
        'getDownloadsDirectory',
      ]) {
        expect(filesContaining(sources, api), isEmpty, reason: api);
      }
      expect(sources['lib/data/local/file_secure_store.dart'], contains('getApplicationSupportDirectory'));
    });

    test('the keychain item never leaves this device (no iCloud Keychain, no backup)', () {
      expect(sources['lib/data/local/file_secure_store.dart'], contains('first_unlock_this_device'));
    });
  });

  group('nothing is offered to other apps', () {
    test('no selectable text, which would bring up Share / Translate / Look Up', () {
      for (final widget in ['SelectableText', 'SelectionArea', 'SelectableRegion']) {
        expect(filesContaining(sources, widget), isEmpty, reason: widget);
      }
    });

    test('every text field is private, except e-mail and password at sign in and sign up', () {
      const allowed = {
        'lib/presentation/shared_widgets/private_input.dart', // the wrappers themselves
        'lib/presentation/auth/views/login_view.dart', // password managers are the user's own choice
        'lib/presentation/auth/views/register_view.dart',
      };
      expect(filesContaining(sources, RegExp(r'\bTextField\('), except: allowed), isEmpty);
      expect(filesContaining(sources, RegExp(r'\bTextFormField\('), except: allowed), isEmpty);
    });

    test('no dependency that shares, opens, tracks or reports', () {
      final pubspec = read('pubspec.yaml');
      final deps = pubspec.substring(pubspec.indexOf('\ndependencies:'), pubspec.indexOf('\ndev_dependencies:'));
      for (final banned in [
        'share_plus',
        'share:',
        'url_launcher',
        'open_filex',
        'open_file',
        'flutter_email_sender',
        'file_picker',
        'image_picker',
        'printing',
        'pdf:',
        'firebase_analytics',
        'firebase_crashlytics',
        'firebase_performance',
        'sentry',
        'google_mobile_ads',
        'facebook',
        'appsflyer',
        'mixpanel',
        'amplitude',
        'clipboard', // packages that bypass the private clipboard
      ]) {
        expect(deps.contains(banned), isFalse, reason: 'dependency "$banned"');
      }
    });
  });

  group('Android', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    final noComments = manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    test('no system backup or device transfer of app data', () {
      expect(noComments, contains('android:allowBackup="false"'));
      expect(noComments, contains('android:fullBackupContent="false"'));
      final rules = read('android/app/src/main/res/xml/data_extraction_rules.xml');
      for (final section in ['cloud-backup', 'device-transfer']) {
        final body = RegExp('<$section>(.*?)</$section>', dotAll: true).firstMatch(rules)!.group(1)!;
        for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
          expect(body, contains('<exclude domain="$domain" />'), reason: '$section must exclude $domain');
        }
      }
    });

    test('no <queries>: the selection menu can not offer other apps (Translate, Search...)', () {
      expect(noComments.contains('<queries'), isFalse);
      expect(noComments.contains('PROCESS_TEXT'), isFalse);
    });

    test('nothing can launch or feed the app except the launcher', () {
      expect(RegExp('<intent-filter').allMatches(noComments).length, 1, reason: 'only the launcher filter');
      expect(RegExp('android:exported="true"').allMatches(noComments).length, 1, reason: 'only the main activity');
      for (final leak in [
        'android.intent.action.SEND',
        'android.intent.action.VIEW',
        'android:scheme',
        '<provider',
        '<receiver',
        '<service',
      ]) {
        expect(noComments.contains(leak), isFalse, reason: leak);
      }
      expect(noComments.contains('usesCleartextTraffic="true"'), isFalse);
      expect(noComments.contains('android:debuggable'), isFalse);
    });

    test('the only permission is the biometric prompt', () {
      final permissions = RegExp(
        r'<uses-permission android:name="([^"]+)"',
      ).allMatches(noComments).map((m) => m.group(1)).toList();
      expect(permissions, ['android.permission.USE_BIOMETRIC']);
    });

    test('screenshots, recordings and the recents preview are blocked; copy is flagged sensitive', () {
      final activity = read('android/app/src/main/kotlin/com/example/myapp/MainActivity.kt');
      expect(activity, contains('FLAG_SECURE'));
      expect(activity, contains('EXTRA_IS_SENSITIVE'));
      expect(activity, contains('chatminusis/private_clipboard'));
    });
  });

  group('iOS', () {
    final plist = read('ios/Runner/Info.plist');
    final delegate = read('ios/Runner/AppDelegate.swift');

    test('the Files app and other apps can not open the app\'s data or documents', () {
      for (final key in [
        'UIFileSharingEnabled',
        'LSSupportsOpeningDocumentsInPlace',
        'CFBundleDocumentTypes',
        'CFBundleURLTypes',
        'UTExportedTypeDeclarations',
        'UTImportedTypeDeclarations',
        'NSUbiquitousContainers',
      ]) {
        expect(plist.contains('<key>$key</key>'), isFalse, reason: key);
      }
    });

    test('the vault is excluded from iCloud and computer backups', () {
      expect(delegate, contains('vault'));
      expect(delegate, contains('isExcludedFromBackup = true'));
    });

    test('copy stays on this device and expires; the app switcher shows no content', () {
      expect(delegate, contains('.localOnly: true'));
      expect(delegate, contains('.expirationDate'));
      expect(delegate, contains('chatminusis/private_clipboard'));
      expect(delegate, contains('UIBlurEffect'));
    });
  });
}
