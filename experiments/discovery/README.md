# Discovery experiment

> This experiment grew into the core's [discover](../../core/src/discover.zig). Its code was removed after commit `92243e1`; `git checkout 92243e1 -- experiments/discovery` restores it, to rerun the measurements below.

Tests what is now **Discovery** in [AGENTS.md](../../AGENTS.md): advertising and finding repositories on the LAN through the system's own DNS-SD service, from Zig, with no dependencies.

## Running

```sh
zig build --release=fast
./zig-out/bin/discover [seconds]     # browse each service type this long (default 2)
```

## Design

`src/main.zig` declares the half-dozen `dns_sd.h` functions it needs (`DNSServiceRegister`, `DNSServiceBrowse`, `DNSServiceResolve`, and the socket and dispatch calls) and:

1. registers a repository named `perihelion` as `_cinematheque._tcp` on port 8090, with a TXT record of what a peer needs before connecting (`version`, `path`, `index`);
2. browses `_cinematheque._tcp`, `_http._tcp`, and `_webdav._tcp`, polling the service's socket;
3. resolves each Cinematheque service found to a host, port, and TXT record.

On macOS the functions are in libSystem; on Linux, Avahi's compatibility library (`libdns_sd`) provides them, which the build links there. Windows has a different API (`DnsServiceRegister` and `DnsServiceBrowse` in `windns.h`).

## Results

On macOS 27.2, the service registered, was found on both loopback and Wi-Fi, and resolved to the host's `.local` name, port 8090, and the TXT record intact. No `_http._tcp` or `_webdav._tcp` services were on this network.

On Linux (Alpine 3.24 in a VM, with `avahi-daemon` and Avahi's `libdns_sd`), the same code, cross-compiled from macOS, registered, browsed, and resolved alike, and the Mac's `dns-sd -L` found the VM's service across the virtual network, TXT record and all. Avahi prints a warning to use its native API instead of the compatibility library.

## Findings

* **The system service is enough:** about 120 lines of Zig, no library, and no fight over the multicast port with the system's own responder.
* **TXT records must be exact:** each string is length-prefixed, and one wrong length made registration fail with no detail, so build them in code, not by hand.
* **A service appears once per interface,** so peers should deduplicate by name before resolving.
* **Bonjour and Avahi interoperate,** so a Linux repository is found from a Mac and the reverse; Avahi's warning suggests binding its native API on Linux eventually.
* **Not yet tested:** Windows, iOS and tvOS (which need `NSBonjourServices` and local network permission), and finding a NAS's own web server.
