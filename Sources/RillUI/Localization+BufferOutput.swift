import Foundation

extension L10n {
  public enum BufferOutputMessage: String {
    case focusTarget, unsupportedControl, empty, processing, draft, operationFailed, rejected, settlementPending, settlementFailed, retryTarget, retryFailed
  }

  public static func bufferOutputMessage(_ message: BufferOutputMessage) -> LocalizedStringResource {
    resource("bufferOutput.\(message.rawValue)")
  }

  public static func bufferDragTitle(asFile: Bool, language: AppLanguage) -> String {
    catalogString(asFile ? "bufferOutput.dragPNG" : "bufferOutput.dragCopy", language: language)
  }
}
