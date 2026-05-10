import Foundation

struct SimctlDeviceList: Codable {
    let devices: [String: [SimctlDevice]]
}

struct SimctlDevice: Codable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let deviceTypeIdentifier: String?
    let lastBootedAt: String?

    var isBooted: Bool { state == "Booted" }
}

extension SimctlDevice {
    /// Derives a human-readable OS name from the runtime key.
    /// e.g. "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → "iOS 17.5"
    static func osName(from runtimeKey: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtimeKey.hasPrefix(prefix) else { return runtimeKey }
        let slug = String(runtimeKey.dropFirst(prefix.count))  // e.g. "iOS-17-5"
        let parts = slug.components(separatedBy: "-")
        guard parts.count >= 2 else { return slug }
        let platform = parts[0]                               // "iOS"
        let version  = parts.dropFirst().joined(separator: ".") // "17.5"
        return "\(platform) \(version)"
    }
}
