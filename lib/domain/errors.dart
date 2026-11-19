/// Too many requests of the same kind in a short time (enforced by the server).
class RateLimitedException implements Exception {
  const RateLimitedException();
}
