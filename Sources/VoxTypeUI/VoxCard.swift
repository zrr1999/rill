import SwiftUI

extension View {
    func voxCard(cornerRadius: CGFloat = 14, opacity: Double = 0.3, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(opacity), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
