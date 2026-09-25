import SwiftUI

public struct SettingsWindowView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView(selection: $model.selectedSettingsPane) {
            ForEach(SettingsPane.allCases) { pane in
                SettingsView(model: model, pane: pane)
                    .tabItem { Label(pane.title(language: model.settings.language), systemImage: pane.symbolName) }
                    .tag(pane)
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 640)
    }
}
