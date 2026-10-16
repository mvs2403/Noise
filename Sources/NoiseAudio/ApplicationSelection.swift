import Foundation

public struct ApplicationSelection: Equatable, Sendable {
    public let applications: [ApplicationReference]
    public var ids: Set<String> { Set(applications.map(\.id)) }
    public var summary: String {
        guard let first = applications.first else { return "Select applications…" }
        if applications.count == 1 { return first.name }
        let others = applications.count - 1
        return "\(first.name) + \(others) \(others == 1 ? "app" : "apps")"
    }

    public init(_ applications: [ApplicationReference] = []) {
        var seen = Set<String>()
        self.applications = applications.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public init(restoring data: Data?, legacyBundleID: String?, available: [AudioApplication]) {
        if let data, let saved = try? JSONDecoder().decode([ApplicationReference].self, from: data) {
            self.init(saved)
        } else if let id = legacyBundleID, !id.isEmpty {
            self.init([available.first { $0.id == id }?.reference ?? ApplicationReference(id: id, name: id)])
        } else {
            self.init()
        }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(applications) }

    // Closed apps remain selected; discovery resolves fresh process IDs when they open.
    public func resolve(in available: [AudioApplication]) -> [AudioApplication] {
        applications.map { saved in
            available.first { $0.id == saved.id }
                ?? AudioApplication(id: saved.id, name: saved.name, processIDs: [], bundleURL: saved.bundleURL)
        }
    }
}
