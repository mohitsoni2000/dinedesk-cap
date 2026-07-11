import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Live Activity / Dynamic Island bridge ("crew/surfaces").
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CrewSurfaces") {
      let channel = FlutterMethodChannel(
        name: "crew/surfaces",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        LiveActivityBridge.handle(call: call, result: result)
      }
    }
  }
}
