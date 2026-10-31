import Foundation

/// Unofficial fork: finds `_remotepairing._tcp` services on the LAN, the
/// RemotePairing tunnel endpoint a paired Apple TV advertises (the manual-pairing
/// service only accepts the PIN pairing, not tunnels). Apple TV pairings carry no
/// alt IRK, so every resolved endpoint is returned and the Rust side tries each
/// one; pair-verify fails fast on devices this pairing file doesn't belong to.
@MainActor
final class AppleTVTunnelResolver: NSObject {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var endpoints: [String: SelfEndpoint] = [:]

    static func resolve(timeout: TimeInterval) async -> [SelfEndpoint] {
        let resolver = AppleTVTunnelResolver()
        resolver.browser.delegate = resolver
        resolver.browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        resolver.browser.stop()
        resolver.services.forEach { $0.stop() }
        // Skip this iPhone's own service (only reachable through LocalDevVPN anyway).
        let own = ProcessInfo.processInfo.hostName.lowercased()
        return resolver.endpoints.values
            .filter { $0.host.lowercased() != own }
            .sorted { $0.host < $1.host }
    }

    fileprivate func found(_ service: NetService) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    fileprivate func resolved(_ service: NetService) {
        guard let host = service.hostName, service.port > 0 else { return }
        let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func value(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
        endpoints["\(host):\(service.port)"] = SelfEndpoint(
            host: host, port: service.port,
            identifier: value("identifier"), authTag: value("authTag"))
    }
}

extension AppleTVTunnelResolver: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in self.found(service) }
    }
}

extension AppleTVTunnelResolver: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in self.resolved(sender) }
    }
}
