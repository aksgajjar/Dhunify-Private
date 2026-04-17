//
//  NetworkMonitor.swift
//  Dhunify
//
//  Monitors network connectivity using NWPathMonitor.
//  Observable singleton — UI reacts instantly to changes.
//

import Foundation
import Network

@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    var isConnected: Bool = true
    var connectionType: String = "wifi"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.diphoria.Dhunify.network")

    private init() {
        monitor.pathUpdateHandler = { path in
              Task { @MainActor [weak self] in
                  guard let self else { return }
                self.isConnected = path.status == .satisfied
                if path.usesInterfaceType(.wifi) {
                    self.connectionType = "wifi"
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = "cellular"
                } else {
                    self.connectionType = "none"
                }
            }
        }
        monitor.start(queue: queue)
    }
}
