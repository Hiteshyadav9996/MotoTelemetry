import Foundation
import Network
import Combine

@MainActor
final class UDPReceiver: ObservableObject {
    @Published var telemetry: Telemetry = .placeholder
    @Published var status: String = "waiting for UDP telemetry"

    private let queue = DispatchQueue(label: "dominar.telemetry.udp")
    private var listener: NWListener?

    func start(port: UInt16 = 4210) {
        guard listener == nil else { return }

        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let newListener = try NWListener(using: .udp, on: nwPort)
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.status = "listening on UDP \(port)"
                    case .failed(let error): self?.status = "UDP listener failed: \(error)"
                    case .cancelled: self?.status = "UDP listener stopped"
                    default: break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .global())
                self?.receive(on: connection)
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            status = "could not start UDP listener: \(error)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.decode(data)
            }
            if error == nil {
                self?.receive(on: connection)
            }
        }
    }

    private func decode(_ data: Data) {
        do {
            let packet = try JSONDecoder().decode(Telemetry.self, from: data)
            Task { @MainActor in
                self.telemetry = packet
                self.status = "packet #\(packet.seq) from \(packet.source)"
            }
        } catch {
            Task { @MainActor in
                self.status = "decode error: \(error.localizedDescription)"
            }
        }
    }
}
