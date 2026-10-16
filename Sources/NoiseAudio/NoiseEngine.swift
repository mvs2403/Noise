import Foundation

public enum NoiseEngine: Int, CaseIterable, Identifiable, Codable, Sendable {
    case dpdfnet = 0
    case deepFilterNet = 1
    case rnnoise = 2
    public var id: Int { rawValue }
    public var name: String {
        switch self {
        case .dpdfnet: "DPDFNet"
        case .deepFilterNet: "DeepFilterNet3"
        case .rnnoise: "RNNoise"
        }
    }
    public var detail: String {
        switch self {
        case .dpdfnet: "Newer speech enhancement · 48 kHz balanced model"
        case .deepFilterNet: "Established full-band speech enhancement · 48 kHz"
        case .rnnoise: "Lightweight speech denoiser · 48 kHz"
        }
    }
    public var library: String {
        switch self {
        case .dpdfnet: "libsherpa-onnx-c-api.dylib"
        case .deepFilterNet: "libdf.dylib"
        case .rnnoise: "librnnoise.dylib"
        }
    }
    public var model: String? {
        switch self {
        case .dpdfnet: "dpdfnet2_48khz_hr.onnx"
        case .deepFilterNet: "DeepFilterNet3_onnx.tar.gz"
        case .rnnoise: nil
        }
    }
}

public struct RuntimePaths: Sendable {
    public let libraries: URL
    public let models: URL
    public init(resources: URL) {
        libraries = resources.appendingPathComponent("Runtime")
        models = resources.appendingPathComponent("Models")
    }
    public init(root: URL? = nil) {
        if let root {
            libraries = root.appendingPathComponent("Vendor/Sherpa/lib")
            models = root.appendingPathComponent("Resources/Models")
        } else if let resources = Bundle.main.resourceURL,
                  FileManager.default.fileExists(atPath: resources.appendingPathComponent("Runtime").path) {
            libraries = resources.appendingPathComponent("Runtime")
            models = resources.appendingPathComponent("Models")
        } else {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOISE_WORKSPACE_ROOT"] ?? FileManager.default.currentDirectoryPath)
            libraries = root.appendingPathComponent("Vendor/Sherpa/lib")
            models = root.appendingPathComponent("Resources/Models")
        }
    }
    public func isAvailable(_ engine: NoiseEngine) -> Bool {
        FileManager.default.fileExists(atPath: libraries.appendingPathComponent(engine.library).path) &&
        (engine.model.map { FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) } ?? true)
    }
    public var mainSpeakerAvailable: Bool {
        FileManager.default.fileExists(atPath: libraries.appendingPathComponent("libweya_nc.dylib").path) &&
        FileManager.default.fileExists(atPath: models.appendingPathComponent("hush-main-speaker.tar.gz").path)
    }
}

public struct AudioFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
