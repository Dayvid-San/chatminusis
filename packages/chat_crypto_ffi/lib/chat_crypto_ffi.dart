/// End-to-end encryption core (MLS / RFC 9420) exposed to Dart.
///
/// Call `await RustLib.init()` once at startup before using [ChatCryptoClient].
library;

export 'src/rust/api/client.dart';
export 'src/rust/frb_generated.dart' show RustLib;
