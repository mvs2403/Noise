import Foundation
import CoreAudio

public struct ApplicationReference: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleURL: URL?

    public init(id: String, name: String, bundleURL: URL? = nil) {
        self.id = id; self.name = name; self.bundleURL = bundleURL
    }
}

public struct AudioApplication: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let processIDs: [AudioObjectID]
    public let bundleURL: URL?
    public let isOutputActive: Bool
    public var reference: ApplicationReference { ApplicationReference(id: id, name: name, bundleURL: bundleURL) }

    public init(id: String, name: String, processIDs: [AudioObjectID], bundleURL: URL? = nil, isOutputActive: Bool = false) {
        self.id = id; self.name = name; self.processIDs = processIDs
        self.bundleURL = bundleURL; self.isOutputActive = isOutputActive
    }
}

// One tap and one processor consume the union, including browser/Electron helpers.
public struct AudioApplicationGroup: Equatable, Sendable {
    public let bundleIDs: [String]
    public let processIDs: [AudioObjectID]
    public init(applications: [AudioApplication]) {
        bundleIDs = Array(Set(applications.map(\.id).filter { !$0.isEmpty })).sorted()
        processIDs = Array(Set(applications.filter { !$0.id.isEmpty }.flatMap(\.processIDs))).sorted()
    }
}
