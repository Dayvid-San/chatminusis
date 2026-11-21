/// Registers this device for content-free push notifications.
abstract class PushRegistry {
  Future<void> register(String uid);
  Future<void> unregister(String uid);
}
