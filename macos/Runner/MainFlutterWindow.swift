import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let openerChannel = FlutterMethodChannel(
      name: "com.mjolnir.app/file_opener",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    openerChannel.setMethodCallHandler { (call, result) in
      if call.method == "openInTextEditor" {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing file path", details: nil))
          return
        }
        let fileURL = URL(fileURLWithPath: path)
        let workspace = NSWorkspace.shared

        if #available(macOS 12.0, *),
           let editorURL = workspace.urlForApplication(toOpen: .plainText) {
          let config = NSWorkspace.OpenConfiguration()
          workspace.open([fileURL], withApplicationAt: editorURL, configuration: config) { _, error in
            DispatchQueue.main.async {
              if let error = error {
                if workspace.open(fileURL) {
                  result(true)
                } else {
                  result(FlutterError(code: "OPEN_FAILED", message: error.localizedDescription, details: nil))
                }
              } else {
                result(true)
              }
            }
          }
        } else {
          let ok = workspace.open(fileURL)
          result(ok)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    self.title = "Mjölnir"

    super.awakeFromNib()
  }
}
