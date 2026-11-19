/// Too many requests of the same kind in a short time (enforced by the server).
class RateLimitedException implements Exception {
  const RateLimitedException();
}

/// The operation needs a login made in the last few minutes.
class ReauthRequiredException implements Exception {
  const ReauthRequiredException();
}
