/// Serializes async operations: the MLS state must change one step at a time.
class SerialQueue {
  Future<void> _last = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _last.then((_) => action());
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }
}
