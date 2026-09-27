import AppKit
import InputMethodKit
import RillInputMethodContracts
import RillInputMethodKit

@main
@MainActor
enum RillInputMethodMain {
  static func main() {
    let library = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Frameworks/librime.1.dylib")
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--probe-profile" {
      do {
        guard arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let inputs = try JSONDecoder().decode(
          [String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let results = try RimeProfileProbe.replay(
          library: library, directory: URL(fileURLWithPath: arguments[1]), inputs: inputs)
        try JSONEncoder().encode(results).write(
          to: URL(fileURLWithPath: arguments[3]), options: .atomic)
      } catch { exit(1) }
      return
    }
    let application = NSApplication.shared
    let lifecycle = InputMethodLifecycle()
    application.delegate = lifecycle
    application.setActivationPolicy(.accessory)
    do {
      RillInputController.engine = try RimeEngine(
        library: library, directory: InputMethodPaths.dataDirectory)
    } catch {
      NSLog("Rill input method cannot open its imported profile.")
      return
    }
    RillInputController.learning = try? InputMethodLearningClient()
    let server = IMKServer(
      name: InputMethodPaths.connectionName, bundleIdentifier: InputMethodPaths.bundleIdentifier)
    withExtendedLifetime((server, lifecycle)) { application.run() }
    lifecycle.shutdown()
  }
}

@MainActor
private final class InputMethodLifecycle: NSObject, NSApplicationDelegate {
  private var stopped = false
  func applicationWillTerminate(_ notification: Notification) { shutdown() }
  func shutdown() {
    guard !stopped else { return }
    stopped = true
    RillInputController.learning?.shutdown()
    RillInputController.engine?.shutdown()
    RillInputController.learning = nil
    RillInputController.engine = nil
  }
}
