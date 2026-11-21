import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var privacyCover: UIView?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeVaultFromBackup()
    // Hide conversations from the app switcher snapshot.
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(coverContent), name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(uncoverContent), name: UIApplication.didBecomeActiveNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerPrivateClipboard(engineBridge)
  }

  /// Keys and message history live in Application Support/vault. Without this, iOS would
  /// include that folder in iCloud and computer backups; the messages must exist only on this device.
  private func excludeVaultFromBackup() {
    guard var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    dir.appendPathComponent("vault", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
  }

  /// The only way a message leaves the app is the user choosing "Copy". On iOS the copy is
  /// local-only (never shared to the user's other devices by Universal Clipboard) and expires.
  private func registerPrivateClipboard(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PrivateClipboard") else { return }
    let channel = FlutterMethodChannel(name: "chatminusis/private_clipboard", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "copy",
            let args = call.arguments as? [String: Any],
            let text = args["text"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIPasteboard.general.setItems(
        [["public.utf8-plain-text": text]],
        options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]
      )
      result(nil)
    }
  }

  private var keyWindow: UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
  }

  @objc private func coverContent() {
    guard privacyCover == nil, let window = keyWindow else { return }
    let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    cover.frame = window.bounds
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(cover)
    privacyCover = cover
  }

  @objc private func uncoverContent() {
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }
}
