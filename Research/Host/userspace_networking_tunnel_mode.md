# `tunnel` mode, stage 1: frames, ARP, DHCP, ICMP

First of three stages of the userspace network described in
`vpn_safe_networking_design.md`. This stage makes the guest believe it is on a
LAN with a gateway; it does **not** yet reach the internet.

## What exists now

A new network mode, `tunnel`, alongside `nat` / `bridged` / `none`:

```
vphone-cli vm config <name> --network tunnel
```

It attaches `VZFileHandleNetworkDeviceAttachment` — the one attachment that
performs no networking of its own, handing raw Ethernet frames to this process
over a `SOCK_DGRAM` socket pair (`socketpair(AF_UNIX, SOCK_DGRAM, 0, …)`; each
`send`/`recv` is exactly one frame, no length prefix).

| file | role |
| --- | --- |
| `VPhoneCoreKit/Network/VPhoneUserspaceNetwork.swift` | socket pair, read source, frame loop, lifetime |
| `VPhoneCoreKit/Network/VPhoneInternetProtocol.swift` | addresses, checksums, Ethernet/IPv4/UDP codecs |
| `VPhoneCoreKit/Network/VPhoneUserspaceNetworkResponder.swift` | ARP, DHCP, ICMP; learned guest MAC |

## Addressing

Identical to the v1.x tunnel work, and for the same reasons:

| | |
| --- | --- |
| Subnet | `192.168.127.0/24` — deliberately not vmnet's `192.168.64.0/24`, so `tunnel` and `nat` can coexist |
| Gateway / DNS / `server-id` | `192.168.127.1` |
| Lease | `192.168.127.3` |
| DHCP options | `1` netmask, `3` router, `6` DNS, `26` MTU 1280, `51` lease, `53` type, `54` server-id |
| Gateway MAC | `02:00:00:00:00:01` (locally administered) |

The guest's own MAC is **not** configurable: Virtualization.framework assigns it
and never reports it, so the responder learns it from the first frame the guest
sends. That is the only piece of state the protocol handling keeps.

## Threading

One serial queue (`com.vphone.userspace-network`). Frame reads arrive as
`DispatchSource` events on it, `stop()` hops onto it before tearing down, and
every field is touched only there — which is the whole invariant behind the
class's `@unchecked Sendable`.

`stop()` is one-way: cancelling the read source closes our descriptor once no
handler is running, so `start()` after `stop()` does nothing rather than
resurrecting a closed pair.

## Verified

Unlike the firmware work, this needs no VM and no privilege — the responder is a
pure function from frame to frame, so it can be driven directly. A throwaway
driver compiled the two Foundation-only files and synthesised frames, 38 checks,
all passing: DHCP `DISCOVER`→`OFFER` and `REQUEST`→`ACK` (message type, lease in
`yiaddr`, echoed `chaddr`, ports 67→68, broadcast MAC, and each addressing
option), ARP request/reply/ignore cases, ICMP echo with a checksum that verifies
to zero, and the robustness cases (short frames, missing DHCP magic cookie,
fragments, empty input).

Reproduce it without the driver:

```
swiftc -O -o /tmp/nettest \
  VPhoneKit/VPhoneCoreKit/Network/VPhoneInternetProtocol.swift \
  VPhoneKit/VPhoneCoreKit/Network/VPhoneUserspaceNetworkResponder.swift \
  <driver>.swift && /tmp/nettest
```

The same checks exist as Swift Testing cases in
`VPhoneCoreKitTests/Network/VPhoneUserspaceNetworkTests.swift`; run them with the
`VPhoneCoreKitTests` target.

Two bugs were found this way rather than in a VM: a duplicate `datagram`
binding in the DHCP path (a compile error), and a test that fed the payload into
the IPv4 header checksum (the checksum covers the header only).

## What stage 1 does *not* do

`tunnel` currently reaches the gateway and nothing else. The guest will get a
lease, resolve the gateway's MAC, and ping `192.168.127.1`, but every packet
destined beyond it is dropped:

| | stage |
| --- | --- |
| ARP, DHCP, ICMP to gateway | **1 (this)** |
| UDP + DNS | 2 |
| TCP (the real egress) | 3 |

That is expected, not a misconfiguration. The mode is not usable for real
traffic until stage 3, which is also where the VPN payoff appears.
