# VPN-safe networking: a design that fits inside the Xcode build

Re-does the network half of #475 against the current tree. The display half of
that PR is already submitted separately (trackpad scroll/pinch and Esc).

## The problem

`VZNATNetworkDeviceAttachment` is not a self-contained NAT. It reuses macOS
Internet Sharing / vmnet, which installs pf rules pinned to the **physical**
interface (`nat on en5 …-> (en5:0)`) and puts the guest on `192.168.64.0/24`.
When a VPN owns the default route (`utun*`), the host's own egress leaves via
the tunnel while the guest's is still written out the physical NIC, and the two
directions stop matching: every guest connection is black-holed. `bridged` does
not help — `VZBridgedNetworkDeviceAttachment` only enumerates physical
interfaces, so a VPN interface cannot be bridged. See #464, and
`Research/Host/userspace_networking_gvproxy.md` for the v1.x investigation.

What is needed is simply: **guest egress that follows the host's routing table**,
VPN included.

## The constraint

From Lakr233 on #475:

> the bundle can only use **system libraries and its own built contents** at
> runtime, so a downloaded `gvproxy` binary can't ship in it. A design that fits
> inside the Xcode build would be needed there.

Read precisely, this excludes *a binary fetched at runtime* (gvproxy, aria2c,
Homebrew). It does **not** exclude source compiled into the bundle — the project
already ships vendored C that way (`VPhoneExecutable/VPhoneCommand/VPhoneRestore`
over libirecovery + idevicestore, both C targets). `Build/ValidateBundle.sh`
enforces this at build time: it walks `otool -L` over the bundle and fails on any
absolute path.

Also excluded by existing project rules:

| Approach | Why it is out |
| --- | --- |
| `pf` anchor + `utun` | needs root; `vphone-cli` never obtains root, and Launchpad's helper has no generic verb |
| `NetworkExtension` | needs an entitlement and user-granted system extension approval |
| Shipping a prebuilt helper | the constraint above |

Unprivileged, self-contained designs only.

One clarification, because it is easy to misread: *unprivileged* here means *no
additional privilege*, not *no entitlements*. `vphone-vm` already carries
`com.apple.vm.networking`, and every attachment in play sits inside that same
set:

| attachment | needs `com.apple.vm.networking` |
| --- | --- |
| `VZNATNetworkDeviceAttachment` | yes |
| `VZBridgedNetworkDeviceAttachment` | yes (it also gates interface enumeration) |
| `VZFileHandleNetworkDeviceAttachment` | no |

The v1.x work emphasised "no entitlement needed" because `gvproxy` was a
separate process and could not inherit `vphone-vm`'s entitlements. A stack built
into the bundle runs inside `vphone-vm` and is in that same set either way. So
the new mode's advantage is **not** privilege — it is the egress path.

## Candidate designs

### A. A userspace stack in Swift

The guest NIC becomes `VZFileHandleNetworkDeviceAttachment` (raw L2 frames over a
socketpair, no entitlement needed). A Swift stack in the bundle terminates ARP,
DHCP, IPv4, ICMP, UDP and TCP, carrying those payloads over ordinary host
sockets — so egress follows the host routing table for free, exactly like the
v1.x gvproxy design did, without the helper binary.

- **Cost**: the largest single piece. Roughly: frame I/O + ARP + DHCP + ICMP
  ≈ 500 lines; UDP + DNS ≈ 300; **TCP ≈ 800–1200** (sequence bookkeeping,
  receive windows, retransmit on a lossless local link).
- **Risk**: TCP correctness. Mitigated by the link being reliable and
  low-latency (a unix socketpair), which is what lets a simplified state machine
  be honest rather than fragile.
- **Fit**: zero third-party code; every line is "its own built contents".

### B. A vendored C stack

Take an existing C stack (lwIP is BSD-licensed, ~50k lines) as a target, then
write a thin forwarding layer that terminates connections and dials out over
host sockets — the shape slirp uses.

- **Cost**: less Swift, but lwIP needs a port layer (`sys_arch`, `lwipopts.h`)
  and has **no ready-made NAT/forward application**, so the forwarding layer is
  still ours (≈400–600 lines).
- **Risk**: a 50k-line dependency the bundle gate cannot inspect beyond its
  binary linkage, against a project that is otherwise careful about
  dependencies. Precedent exists (VPhoneRestore) but it is deliberately narrow.

### C. Guest-side forwarding over vsock

Run a userland forwarder inside the guest (tun2socks-shaped), reachable over
vsock — which does not depend on the NIC at all — and have it hand TCP to a
SOCKS5 server in `vphone-vm` built on Network.framework.

- **Cost**: the host side is the smallest of the three (~400 lines). The guest
  side is the expensive half: cross-compiling a guest component, taking over the
  guest's routing, and keeping that in step with guest updates.
- **Risk**: it changes the guest's whole network behaviour rather than adding a
  mode, and guest components ship as payload (a different review surface).
  Only chosen if the host-side stack proves impractical.

## Recommendation

**A**, built in three stages so each is independently testable:

1. **Frames, ARP, DHCP, ICMP.** The guest gets an address, resolves the
   gateway, and can ping it. Provable without any egress.
2. **UDP and DNS.** Name resolution works through the host resolver.
3. **TCP.** Full egress; this is where the design earns its keep.

Each stage is a separate commit behind the same `VPHONE_NET_*`-style switch as
today's features, so `nat`/`bridged`/`off` stay untouched.

Worth stating plainly: this is a **mode**, not a fix for `nat`. `nat` stays
broken behind a VPN by design of vmnet; the new mode is what a user picks when
they are behind one.

## What the implementation would touch

| File | Role |
| --- | --- |
| `VPhoneKit/VPhoneCoreKit/Support/VPhoneNetworking.swift` | a new mode in `NetworkMode`, device construction |
| new `VPhoneKit/.../Support/VPhoneUserspaceNetwork*.swift` | the stack (frame I/O, ARP/DHCP/ICMP, UDP/DNS, TCP) |
| `VPhoneExecutable/.../VirtualMachine/VPhoneVirtualMachine.swift` | owns the backend's lifetime across a boot |

## Validation

Same shape as the v1.x work, but without the helper: drive the transport the
guest will use (`bind` + `connect` a `SOCK_DGRAM` unix socket to the attachment's
socket), synthesise L2 frames, and compare against the host:

| Probe | Expected |
| --- | --- |
| `DHCP DISCOVER` → `OFFER` | a lease in the mode's subnet |
| ARP for the gateway | reply with the gateway's MAC |
| TCP `SYN` to `1.1.1.1:443` | `SYN-ACK` **with the VPN up** |
| UDP DNS for a public name | an answer, `rcode 0` |
| Egress check | same exit address as the host's own (`ip.sb`-style), i.e. the VPN's |

The last row is the whole point of the exercise, and it is the one thing `nat`
cannot pass.
