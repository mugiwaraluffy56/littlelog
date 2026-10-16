import Foundation
import SwiftData

enum Persistence {
    static let schema = Schema([Note.self, DailyTask.self])

    /// The on-disk library inside the app's sandboxed Application Support directory.
    static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "littlelog",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    static func makeContainer(url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
