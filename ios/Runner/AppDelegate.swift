import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  private var exportResult: FlutterResult?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "app.pocketssh/device", binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self, weak controller] call, result in
        guard call.method == "exportDocument" else { result(FlutterMethodNotImplemented); return }
        guard let self = self, self.exportResult == nil, let controller = controller,
              let path = call.arguments as? String else {
          result(FlutterError(code: "document_picker", message: "文件保存界面不可用", details: nil))
          return
        }
        let picker = UIDocumentPickerViewController(url: URL(fileURLWithPath: path), in: .exportToService)
        picker.delegate = self
        self.exportResult = result
        var presenter: UIViewController = controller
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(picker, animated: true)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = exportResult
    exportResult = nil
    result?(!urls.isEmpty)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = exportResult
    exportResult = nil
    result?(false)
  }
}
