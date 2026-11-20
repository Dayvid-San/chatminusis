// Enforces the module boundaries described in docs/ARQUITETURA.md. If one of
// these fails, fix the dependency, not the test. The only exceptions are the
// couplings listed in [knownCoupling]: they exist today, may only shrink, and
// each new one needs a reason written here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _import = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

/// A project file with the places its imports lead to.
class Src {
  Src(this.path, this.imports);
  final String path; // e.g. lib/features/auth/domain/app_user.dart
  final List<String> imports;

  /// `auth` for lib/features/auth/..., null elsewhere.
  String? get feature => RegExp(r'^lib/features/(\w+)/').firstMatch(path)?.group(1);

  /// `domain`, `data` or `presentation` inside a feature.
  String? get layer => RegExp(r'^lib/features/\w+/(\w+)/').firstMatch(path)?.group(1);
}

/// Where an import of a project file points, as a path under lib/, or null for
/// other packages and dart: libraries.
String? target(Src s, String spec) {
  if (spec.startsWith('package:myapp/')) return 'lib/${spec.substring('package:myapp/'.length)}';
  if (spec.startsWith('package:') || spec.startsWith('dart:')) return null;
  return File(s.path).parent.uri.resolve(spec).toFilePath().replaceFirst('${Directory.current.path}/', '');
}

List<Src> sources(String dir) => [
  for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
    Src(f.path, [for (final m in _import.allMatches(f.readAsStringSync())) m.group(1)!]),
];

/// `feature/layer` of a path under lib/features, e.g. `auth/domain`.
String? areaOf(String path) => RegExp(r'^lib/features/(\w+/\w+)/').firstMatch(path)?.group(1);

/// Cross-feature imports of another feature's presentation or data that exist
/// today (screens that open other features' screens, and the security gate).
const knownCoupling = {
  'messaging/presentation -> auth/presentation', // home: sign-out and the signed-in user
  'messaging/presentation -> profile/presentation', // home opens the profile screen
  'messaging/presentation -> search/presentation', // home opens the search screen
  'messaging/presentation -> security/presentation', // home opens security settings
  'session/presentation -> auth/presentation', // the session wraps the signed-in user
  'session/presentation -> messaging/presentation', // and builds the conversation list
  'session/presentation -> security/data', // and the app lock
};

void main() {
  final app = sources('lib');
  final components = sources('components/lib');

  test('the components package knows nothing about the app', () {
    for (final s in components) {
      for (final i in s.imports) {
        expect(i.startsWith('package:myapp'), isFalse, reason: '${s.path} imports $i');
        expect(i.startsWith('package:chat_crypto_ffi'), isFalse, reason: '${s.path} imports $i');
        if (!i.startsWith('package:') && !i.startsWith('dart:')) {
          final t = File(s.path).absolute.parent.uri.resolve(i).toFilePath();
          expect(t.contains('/components/lib/'), isTrue, reason: '${s.path} reaches outside the package: $i');
        }
      }
    }
  });

  test('the domain layer is plain Dart: no Flutter, no backend SDKs, no data or presentation', () {
    for (final s in app.where((s) => s.layer == 'domain')) {
      for (final i in s.imports) {
        final t = target(s, i);
        if (t == null) {
          final ok = i.startsWith('dart:') || i == 'package:chat_crypto_ffi/chat_crypto_ffi.dart';
          expect(ok, isTrue, reason: '${s.path} imports $i');
        } else {
          final area = areaOf(t);
          expect(area == null || area.endsWith('/domain'), isTrue, reason: '${s.path} imports $t');
        }
      }
    }
  });

  test('core is a shared base: it depends on no feature', () {
    for (final s in app.where((s) => s.path.startsWith('lib/core/'))) {
      for (final i in s.imports) {
        final t = target(s, i);
        expect(t != null && t.startsWith('lib/features/'), isFalse, reason: '${s.path} imports $i');
      }
    }
  });

  test('data implements domain interfaces and never touches the screens', () {
    for (final s in app.where((s) => s.layer == 'data')) {
      for (final i in s.imports) {
        final t = target(s, i);
        expect(t != null && areaOf(t)?.endsWith('/presentation') == true, isFalse, reason: '${s.path} imports $i');
      }
    }
  });

  test('a feature reaches into another only through its domain, apart from the known couplings', () {
    final found = <String>{};
    for (final s in app.where((s) => s.feature != null)) {
      for (final i in s.imports) {
        final t = target(s, i);
        final to = t == null ? null : areaOf(t);
        if (to == null || to.split('/').first == s.feature) continue;
        if (to.endsWith('/domain')) continue;
        found.add('${areaOf(s.path)} -> $to');
      }
    }
    expect(found.difference(knownCoupling), isEmpty, reason: 'new coupling between features');
    expect(knownCoupling.difference(found), isEmpty, reason: 'coupling that is gone: remove it from the list');
  });

  test('only the composition root (main.dart) and the session wire concrete data classes of other features', () {
    for (final s in app.where((s) => s.feature != null && s.path != 'lib/main.dart')) {
      for (final i in s.imports) {
        final t = target(s, i);
        final to = t == null ? null : areaOf(t);
        if (to == null || to.split('/').first == s.feature || !to.endsWith('/data')) continue;
        expect(s.feature == 'session', isTrue, reason: '${s.path} imports $t');
      }
    }
  });

  test('nothing imports a screen from the services or backends of the app', () {
    for (final s in app.where((s) => s.layer == 'domain' || s.layer == 'data')) {
      for (final i in s.imports) {
        expect(i.contains('presentation'), isFalse, reason: '${s.path} imports $i');
      }
    }
  });
}
