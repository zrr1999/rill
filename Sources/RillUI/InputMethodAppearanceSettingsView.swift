import AppKit
import RillInputMethodContracts
import SwiftUI

struct InputMethodAppearanceSettingsView: View {
  @Bindable var model: InputMethodAppearanceModel
  var language: AppLanguage
  @State var isExpanded = false
  @State private var fontPicker = InputMethodFontPicker()

  private var font: NSFont {
    model.draft.fontName.flatMap { NSFont(name: $0, size: model.draft.fontSize) }
      ?? .systemFont(ofSize: model.draft.fontSize)
  }

  var body: some View {
    DisclosureGroup(L10n.inputMethodAppearance(.title, language: language), isExpanded: $isExpanded) {
      Toggle(
        L10n.inputMethodAppearance(.showNumbers, language: language), isOn: $model.draft.showsNumbers
      )
      .accessibilityIdentifier("input-method-show-numbers")
      TextField(
        L10n.inputMethodAppearance(.numberFormat, language: language), text: $model.draft.numberFormat
      )
      .disabled(!model.draft.showsNumbers)
      .accessibilityIdentifier("input-method-number-format")
      Text(L10n.inputMethodAppearance(.numberFormatHelp, language: language))
        .font(.caption).foregroundStyle(.secondary)
      LabeledContent(L10n.inputMethodAppearance(.font, language: language)) {
        Text(
          model.draft.fontName == nil
            ? L10n.inputMethodAppearance(.systemFont, language: language)
            : font.displayName ?? font.fontName
        )
        .lineLimit(1).truncationMode(.middle)
        Button(L10n.inputMethodAppearance(.chooseFont, language: language)) {
          fontPicker.show(font: font) { selected in
            model.draft.fontName = selected.fontName
            model.draft.fontSize = min(
              max(selected.pointSize, InputMethodAppearance.fontSizes.lowerBound),
              InputMethodAppearance.fontSizes.upperBound)
          }
        }
        .accessibilityIdentifier("input-method-choose-font")
      }
      Stepper(value: $model.draft.fontSize, in: InputMethodAppearance.fontSizes, step: 1) {
        LabeledContent(L10n.inputMethodAppearance(.fontSize, language: language)) {
          Text(L10n.inputMethodAppearanceFontSize(model.draft.fontSize, language: language))
            .monospacedDigit()
        }
      }
      .accessibilityIdentifier("input-method-font-size")
      LabeledContent(L10n.inputMethodAppearance(.preview, language: language)) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(["你好", "输入法", "候选词"].enumerated()), id: \.offset) { index, text in
            Text(model.draft.candidateTitle(at: index, text: text, comment: ""))
              .font(Font(font)).lineLimit(1).truncationMode(.tail)
              .foregroundStyle(index == 0 ? Color.accentColor : Color.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("input-method-appearance-preview")
      }
      if let error = model.validationError {
        Text(L10n.inputMethodAppearanceValidationError(error, language: language))
          .font(.caption).foregroundStyle(.red)
      } else if let error = model.storageError {
        Text(L10n.inputMethodAppearance(error == .load ? .loadError : .saveError, language: language))
          .font(.caption).foregroundStyle(.red)
      }
      HStack {
        Button(L10n.inputMethodAppearance(.reset, language: language)) { model.reset() }
          .disabled(model.draft == .defaults && model.saved == .defaults && model.storageError == nil)
        Spacer()
        Button(L10n.inputMethodAppearance(.apply, language: language)) { model.apply() }
          .disabled(!model.canApply)
          .accessibilityIdentifier("input-method-apply-appearance")
      }
    }
    .onAppear { model.loadIfNeeded() }
    .onDisappear { fontPicker.close() }
  }
}

@MainActor
private final class InputMethodFontPicker: NSObject, NSFontChanging {
  private var font = NSFont.systemFont(ofSize: 20)
  private var changed: ((NSFont) -> Void)?
  private weak var previousTarget: AnyObject?
  private var previousAction: Selector?

  func show(font: NSFont, changed: @escaping (NSFont) -> Void) {
    self.font = font
    self.changed = changed
    let manager = NSFontManager.shared
    if (manager.target as AnyObject?) !== self {
      previousTarget = manager.target as AnyObject?
      previousAction = manager.action
    }
    manager.target = self
    manager.action = #selector(changeFont(_:))
    manager.setSelectedFont(font, isMultiple: false)
    manager.orderFrontFontPanel(nil)
  }

  func changeFont(_ sender: NSFontManager?) {
    guard let sender else { return }
    font = sender.convert(font)
    changed?(font)
  }

  func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
    [.collection, .face, .size]
  }

  func close() {
    let manager = NSFontManager.shared
    guard (manager.target as AnyObject?) === self else { return }
    manager.fontPanel(false)?.orderOut(nil)
    manager.target = previousTarget
    if let previousAction { manager.action = previousAction }
    changed = nil
  }
}
