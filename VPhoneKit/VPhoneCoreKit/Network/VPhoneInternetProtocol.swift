import Foundation

// MARK: - Addresses

/// An IPv4 address held in host order. Deliberately not `Network`/`NWAddress`:
/// this type only has to round-trip through byte arrays.
public struct VPhoneIPv4Address: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var raw: UInt32

    public init(_ raw: UInt32) { self.raw = raw }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        raw = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    public var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: raw >> 24), UInt8(truncatingIfNeeded: raw >> 16),
         UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)]
    }

    public var description: String { bytes.map(String.init).joined(separator: ".") }

    /// `255.255.255.255`
    public static let broadcast = VPhoneIPv4Address(255, 255, 255, 255)
    /// `0.0.0.0`
    public static let any = VPhoneIPv4Address(0, 0, 0, 0)
}

// MARK: - Configuration

/// Addressing for the userspace network.
///
/// The subnet deliberately differs from vmnet's `192.168.64.0/24` so `tunnel`
/// and `nat` can coexist on one host without their DHCP servers answering each
/// other. It also sits inside `192.168.0.0/16`, which every mainstream VPN keeps
/// out of its tunnel.
public struct VPhoneUserspaceNetworkConfiguration: Sendable, Equatable {
    /// The address the host answers ARP for, serves DHCP from, and later
    /// appears to be the DNS resolver. Also the DHCP `server-id`.
    public var hostAddress: VPhoneIPv4Address
    /// The lease handed to the guest. One address is enough: one guest per VM.
    public var guestAddress: VPhoneIPv4Address
    /// Advertised through DHCP option 26. 1280 keeps the guest's segments
    /// inside what a VPN tunnel will carry without fragmenting.
    public var mtu: Int

    public static let `default` = VPhoneUserspaceNetworkConfiguration(
        hostAddress: VPhoneIPv4Address(192, 168, 127, 1),
        guestAddress: VPhoneIPv4Address(192, 168, 127, 3),
        mtu: 1280,
    )

    public init(hostAddress: VPhoneIPv4Address, guestAddress: VPhoneIPv4Address, mtu: Int = 1280) {
        self.hostAddress = hostAddress
        self.guestAddress = guestAddress
        self.mtu = mtu
    }
}

/// A 48-bit Ethernet address. The host side uses a locally administered address
/// of its own; the guest's is learned from the first frame it sends, because
/// Virtualization.framework assigns the MAC and never tells us what it picked.
public struct VPhoneMACAddress: Sendable, Equatable, Hashable {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The gateway's address. Locally administered, unicast, and unlikely to
    /// collide with anything.
    public static let gateway = VPhoneMACAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])

    var hexString: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }
}

// MARK: - Checksums

enum VPhoneInternetChecksum {
    /// RFC 1071 internet checksum. `seed` carries a pseudo-header for UDP/TCP.
    static func compute(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt16 {
        var sum = seed
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }
}

// MARK: - Ethernet

enum VPhoneEtherType: UInt16 {
    case ipv4 = 0x0800
    case arp = 0x0806
}

struct VPhoneEthernetFrame {
    var destination: VPhoneMACAddress
    var source: VPhoneMACAddress
    var etherType: UInt16
    var payload: [UInt8]

    init(destination: VPhoneMACAddress, source: VPhoneMACAddress, etherType: VPhoneEtherType, payload: [UInt8]) {
        self.destination = destination
        self.source = source
        self.etherType = etherType.rawValue
        self.payload = payload
    }

    var bytes: [UInt8] {
        destination.bytes + source.bytes + [UInt8(etherType >> 8), UInt8(etherType & 0xFF)] + payload
    }

    /// Parse, or nil if the frame is malformed or too short to address.
    init?(bytes: [UInt8]) {
        guard bytes.count >= 14 else { return nil }
        destination = VPhoneMACAddress(Array(bytes[0 ..< 6]))
        source = VPhoneMACAddress(Array(bytes[6 ..< 12]))
        etherType = UInt16(bytes[12]) << 8 | UInt16(bytes[13])
        payload = Array(bytes[14...])
    }
}

// MARK: - IPv4

enum VPhoneIPProtocol: UInt8 {
    case icmp = 1
    case udp = 17
}

struct VPhoneIPv4Packet {
    var source: VPhoneIPv4Address
    var destination: VPhoneIPv4Address
    var proto: UInt8
    var ttl: UInt8
    var identification: UInt16
    var payload: [UInt8]

    init(
        source: VPhoneIPv4Address,
        destination: VPhoneIPv4Address,
        proto: VPhoneIPProtocol,
        ttl: UInt8 = 64,
        identification: UInt16 = 0,
        payload: [UInt8],
    ) {
        self.source = source
        self.destination = destination
        self.proto = proto.rawValue
        self.ttl = ttl
        self.identification = identification
        self.payload = payload
    }

    var totalLength: Int { 20 + payload.count }

    var bytes: [UInt8] {
        var header: [UInt8] = [
            0x45, 0x00,
            UInt8(truncatingIfNeeded: totalLength >> 8), UInt8(truncatingIfNeeded: totalLength),
            UInt8(truncatingIfNeeded: identification >> 8), UInt8(truncatingIfNeeded: identification),
            0x40, 0x00, // don't fragment: the guest should never exceed our MTU
            ttl, proto,
        ]
        header += [0, 0] // checksum placeholder
        header += source.bytes + destination.bytes
        let sum = VPhoneInternetChecksum.compute(header)
        header[10] = UInt8(sum >> 8)
        header[11] = UInt8(sum & 0xFF)
        return header + payload
    }

    /// Parse, or nil for anything we cannot answer: fragments, options, IPv6.
    init?(bytes: [UInt8]) {
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        guard headerLength >= 20, bytes.count >= headerLength else { return nil }
        // A fragment would need reassembly, which a DHCP/ARP/ICMP responder
        // never sees. Dropping is correct; the guest retries.
        let fragmentOffset = UInt16(bytes[6] & 0x1F) << 8 | UInt16(bytes[7])
        guard fragmentOffset == 0, bytes[6] & 0x20 == 0 else { return nil }
        let declared = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        guard declared >= headerLength, bytes.count >= declared else { return nil }

        source = VPhoneIPv4Address(UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15]))
        destination = VPhoneIPv4Address(UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19]))
        proto = bytes[9]
        ttl = bytes[8]
        identification = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        payload = Array(bytes[headerLength ..< declared])
    }
}

// MARK: - UDP

struct VPhoneUDPDatagram {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: [UInt8]

    init(sourcePort: UInt16, destinationPort: UInt16, payload: [UInt8]) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    func bytes(source: VPhoneIPv4Address, destination: VPhoneIPv4Address) -> [UInt8] {
        let length = 8 + payload.count
        var header: [UInt8] = [
            UInt8(sourcePort >> 8), UInt8(truncatingIfNeeded: sourcePort),
            UInt8(destinationPort >> 8), UInt8(truncatingIfNeeded: destinationPort),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
            0, 0,
        ]
        let datagram = header + payload
        let sum = VPhoneInternetChecksum.compute(
            datagram,
            seed: VPhoneInternetChecksum.pseudoHeader(source: source, destination: destination, proto: 17, length: length),
        )
        // A computed zero is transmitted as all ones (RFC 768).
        header[6] = UInt8((sum == 0 ? 0xFFFF : sum) >> 8)
        header[7] = UInt8((sum == 0 ? 0xFFFF : sum) & 0xFF)
        return header + payload
    }

    init?(bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        sourcePort = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        destinationPort = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let length = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        guard length >= 8, bytes.count >= length else { return nil }
        payload = Array(bytes[8 ..< length])
    }
}

extension VPhoneInternetChecksum {
    /// The UDP/TCP pseudo-header, folded into the running sum.
    static func pseudoHeader(source: VPhoneIPv4Address, destination: VPhoneIPv4Address, proto: UInt8, length: Int) -> UInt32 {
        var sum: UInt32 = 0
        let sourceBytes = source.bytes
        let destinationBytes = destination.bytes
        for index in stride(from: 0, to: 4, by: 2) {
            sum += UInt32(sourceBytes[index]) << 8 | UInt32(sourceBytes[index + 1])
            sum += UInt32(destinationBytes[index]) << 8 | UInt32(destinationBytes[index + 1])
        }
        sum += UInt32(proto)
        sum += UInt32(length)
        return sum
    }
}
