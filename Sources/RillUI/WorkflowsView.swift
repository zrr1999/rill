import SwiftUI

public struct WorkflowsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View { WorkflowDocumentLibraryView(model: model) }
}
