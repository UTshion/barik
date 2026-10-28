import Foundation

nonisolated struct AeroWindow: WindowModel {
    let id: Int
    let title: String
    let appName: String?
    var isFocused: Bool = false
    let workspace: String?

    enum CodingKeys: String, CodingKey {
        case id = "window-id"
        case title = "window-title"
        case appName = "app-name"
        case workspace
    }
}

nonisolated struct AeroSpace: SpaceModel {
    typealias WindowType = AeroWindow
    let workspace: String
    var id: String { workspace }
    var spaceId: String { workspace }
    var isFocused: Bool = false
    var windows: [AeroWindow] = []

    enum CodingKeys: String, CodingKey {
        case workspace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.decode(String.self, forKey: .workspace)
    }
}
