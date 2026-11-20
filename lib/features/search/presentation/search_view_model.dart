import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:myapp/core/utils/nickname.dart';
import 'package:myapp/features/profile/domain/user_profile.dart';
import 'package:myapp/features/profile/domain/profile_repository.dart';

enum SearchState { idle, searching, found, notFound, rateLimited, error }

/// Exact-nickname lookup with a client-side rate limit (anti-enumeration).
class SearchViewModel extends ChangeNotifier {
  SearchViewModel(this._profiles, this._myUid, {DateTime Function()? clock}) : _now = clock ?? DateTime.now {
    _blockedSub = _profiles.watchBlocked(_myUid).listen((b) {
      _blocked = b;
      notifyListeners();
    });
  }

  static const maxSearchesPerMinute = 10;

  final ProfileRepository _profiles;
  final String _myUid;
  final DateTime Function() _now;
  final List<DateTime> _recent = [];
  StreamSubscription<Set<String>>? _blockedSub;

  SearchState _state = SearchState.idle;
  UserProfile? _result;
  Set<String> _blocked = {};
  String _validation = '';

  SearchState get state => _state;
  UserProfile? get result => _result;
  String get validation => _validation;
  bool isBlocked(String uid) => _blocked.contains(uid);

  Future<void> search(String query) async {
    final nick = Nickname.normalize(query);
    _validation = Nickname.validate(nick) ?? '';
    _result = null;
    if (_validation.isNotEmpty) {
      _state = SearchState.idle;
      notifyListeners();
      return;
    }
    final now = _now();
    _recent.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (_recent.length >= maxSearchesPerMinute) {
      _state = SearchState.rateLimited;
      notifyListeners();
      return;
    }
    _recent.add(now);
    _state = SearchState.searching;
    notifyListeners();
    try {
      final found = await _profiles.findByNickname(nick);
      // Never show yourself as a search result.
      _result = found?.uid == _myUid ? null : found;
      _state = _result == null ? SearchState.notFound : SearchState.found;
    } on RateLimitedException {
      _state = SearchState.rateLimited; // the server's own limit
    } catch (_) {
      _state = SearchState.error;
    }
    notifyListeners();
  }

  Future<void> toggleBlock(String otherUid) =>
      _profiles.setBlocked(uid: _myUid, otherUid: otherUid, blocked: !isBlocked(otherUid));

  Future<void> report(String otherUid, String reason) =>
      _profiles.report(reporterUid: _myUid, reportedUid: otherUid, reason: reason);

  @override
  void dispose() {
    _blockedSub?.cancel();
    super.dispose();
  }
}
