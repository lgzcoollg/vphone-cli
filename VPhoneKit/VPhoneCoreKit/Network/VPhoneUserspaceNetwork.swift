import Foundation
import Virtualization

// MARK: - Errors

public enum VPhoneUserspaceNetworkError: Error, Equatable {
    /// `socketpair(2)` failed.
    case socketPairFailed(errno: Int32)
    /// The attachment was asked for before `start()`, or after `stop()`.
    case notRunning
}

extension VPhoneUserspaceNetworkError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .socketPairFailed(errno):
            "Could not create the network device socket pair (errno \(errno))."
        case .notRunning:
            "The userspace network is not running."
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - The device

/// A guest NIC backed entirely by this process.
///
/// `VZFileHandleNetworkDeviceAttachment` hands frames to us untouched — it
/// performs no DHCP, no ARP, no translation — so everything the guest expects a
/// network to do is implemented on this side, in `VPhoneUserspaceNetworkResponder`.
///
/// The point of the mode is egress: replies leave through ordinary host sockets,
/// so they follow the host's routing table and therefore a VPN, with no root, no
/// interface, and no change to the host's configuration. `nat` cannot do that
/// because vmnet's masquerade is pinned to a physical interface.
///
/// Threading: every field is touched only on `queue`, a serial queue. Frame reads
/// arrive as `DispatchSource` events on that queue, and `stop()` hops onto it
/// before tearing down. That is the whole of the invariant behind
/// `@unchecked Sendable`.
public final class VPhoneUserspaceNetwork: @unchecked Sendable {
    public let configuration: VPhoneUserspaceNetworkConfiguration

    /// Our end of the socket pair. The other end belongs to the attachment.
    private let socket: Int32
    /// Held so the attachment (and therefore the VZ device tree) outlives us.
    private let attachment: VZFileHandleNetworkDeviceAttachment
    private let queue = DispatchQueue(label: "com.vphone.userspace-network")
    private var source: DispatchSourceRead?
    /// Set by `stop()`. Cancelling the read source closes our descriptor once no
    /// handler is running, so the pair cannot be reopened after that.
    private var isStopped = false
    private var responder: VPhoneUserspaceNetworkResponder

    /// Largest frame we will accept from the guest. Ethernet header plus a
    /// jumbo-sized IP packet; the guest is expected to stay within `mtu`.
    private static let frameCapacity = 9216

    public init(configuration: VPhoneUserspaceNetworkConfiguration = .default) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw VPhoneUserspaceNetworkError.socketPairFailed(errno: errno)
        }
        // A SOCK_DGRAM pair has a small default buffer, and the guest can burst
        // (a DHCP retry plus an ARP plus a DNS query) faster than we drain it.
        // Dropping frames here would look like packet loss to the guest.
        for descriptor in descriptors {
            var size: Int32 = 4 << 20
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }

        let guestEnd = descriptors[0]
        socket = descriptors[1]
        attachment = VZFileHandleNetworkDeviceAttachment(
            fileHandle: FileHandle(fileDescriptor: guestEnd, closeOnDealloc: true),
        )
        responder = VPhoneUserspaceNetworkResponder(configuration: configuration)
        self.configuration = configuration
    }

    /// The object to hand to `VZVirtioNetworkDeviceConfiguration.attachment`.
    public var networkAttachment: VZNetworkDeviceAttachment { attachment }

    /// Begin draining the guest's frames. Idempotent, and a no-op after `stop()`.
    public func start() {
        queue.sync {
            guard !isStopped, source == nil else { return }
            let descriptor = socket
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            // Closing the source closes the descriptor, but only once no handler
            // is running; VZ holds its own end of the pair until the device goes.
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
    }

    /// Stop draining and close our end. Idempotent. There is no way back: the
    /// descriptor is gone, so a later `start()` does nothing.
    public func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            source?.cancel()
            source = nil
        }
    }

    deinit {
        // Nothing may hop onto `queue` from deinit, so only cancel if we are
        // already on it — which is why `stop()` exists and should be preferred.
        source?.cancel()
    }

    // MARK: - Frame loop

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: Self.frameCapacity)
        while true {
            let received = buffer.withUnsafeMutableBytes { raw in
                recv(socket, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 { return } // EAGAIN once the queue is empty
            let frame = Array(buffer[0 ..< received])
            guard let reply = responder.respond(to: frame) else { continue }
            reply.withUnsafeBytes { raw in
                _ = send(socket, raw.baseAddress, raw.count, 0)
            }
        }
    }
}
