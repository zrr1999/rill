import AppKit
import SwiftUI
import RillUI

@MainActor
enum RillMenuBarIcon {
    static func image(for symbol: RillSystemSymbol) -> Image {
        switch symbol {
        case .waveform:
            ready
        case .squareStack3dUpFill:
            records
        default:
            Image(systemName: symbol.rawValue)
        }
    }

    private static let ready = template(named: "RillMenuBarTemplate")
    private static let records = template(named: "RillMenuBarRecordsTemplate")

    private static func template(named name: String) -> Image {
        // Loose PDF resources need AppKit loading; SwiftUI's named-image
        // initializer does not resolve these exports as asset-catalog images.
        guard let image = Bundle.module.image(forResource: name) else {
            preconditionFailure("Missing bundled menu bar image: \(name)")
        }
        return Image(nsImage: image).renderingMode(.template)
    }
}
