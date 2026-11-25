import CCinematheque
import Foundation

extension Library {
    // Pairing a new device, by a code it shows, with a member's: to be
    // another of that person's devices, or a new member's.

    /// A new device's offer: the code to show, and whether it's paired (it
    /// has the library) or stopped, after too many wrong codes.
    struct Pairing: Codable, Equatable {
        let code: String?
        let paired: Bool
        let closed: Bool
    }

    /// On this device, before it has a library: offers to be added to one,
    /// as a member's device decides (another of theirs, or a new member's),
    /// with a new code.
    func offerPairing() -> Pairing? {
        // As setup leaves, once paired, its screen may ask once more.
        guard !hasLibrary else { return nil }
        return decode(Pairing.self) { cq_pair_offer($0, Platform.deviceName, Platform.model) }
    }

    /// The offer's state; once paired, this device has its person and library.
    func checkPairing() -> Pairing? {
        guard !hasLibrary else { return nil }
        let state = decode(Pairing.self) { cq_pair_check($0) }
        if state?.paired == true {
            dirty = true
            reload()
        }
        return state
    }

    func stopPairing() {
        if let handle { cq_pair_stop(handle.pointer) }
    }

    /// Adds the new device `device` as another of this person's devices,
    /// given the code it shows: sends it the library and this person's
    /// secret, then takes it in (`welcome`). Returns what went wrong, in
    /// words, if anything did.
    func pairPerson(_ device: NearbyDevice, code: String) async -> String? {
        await pair(device, code: code) { cq_pair_person($0, $1, $2) }
    }

    /// As `pairPerson`, as a new member's device: sends it the library
    /// alone, and adds its person as a member.
    func pairMember(_ device: NearbyDevice, code: String) async -> String? {
        await pair(device, code: code, by: { cq_pair_member($0, $1, $2) }) { paired in self.check { cq_member_add($0, paired.person) } }
    }

    private func pair(_ device: NearbyDevice, code: String, by send: @escaping @Sendable (OpaquePointer, String, String) -> UnsafeMutablePointer<CChar>?, admit: (Paired) -> Void = { _ in }) async -> String? {
        let url = device.url
        let name = device.deviceName ?? "The device"
        let called: (Paired?, String?)? = await apart { handle in
            guard let data = coreData(send(handle, url, code)) else { return (nil, String(cString: cq_error())) }
            return (decoded(Paired.self, data), nil)
        }
        guard let (paired, failure) = called else { return "The library isn't open." }
        switch failure {
        case nil:
            guard let paired else { return "Couldn't pair with \(name)." }
            admit(paired)
            welcome(paired, from: device)
            return nil
        case "WrongCode": return "That isn't the code \(name) shows. Check it, and try again."
        case "Closed": return "\(name) stopped taking codes from this \(Self.deviceKind) after too many wrong ones. On it, show a new code."
        case let failure?: return "Couldn't pair with \(name): \(failure)."
        }
    }

    /// What this device is, as a person calls it ("this Mac").
    static var deviceKind: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(iOS)
        "iPhone"
        #else
        "Mac"
        #endif
    }

    /// Renames another of this person's devices (or this one), for every
    /// device: as when its platform won't tell it its own name.
    func renameDevice(_ key: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let person = status?.person else { return }
        checkAndReload { cq_name($0, key, person, trimmed) }
    }

    /// Copy racing (see the core's race.zig): `urls`, an item's copies, in
    /// the order to try them, those whose servers answer first; off the
    /// main thread, for up to 1.5 seconds.
    func race(_ urls: [URL]) async -> [URL] {
        guard urls.count > 1 else { return urls }
        let strings = urls.map(\.absoluteString)
        let ordered = await apart { handle in decoded([String].self, coreData(withCStrings(strings) { cq_race(handle, $0, $1) })) } ?? nil
        return ordered?.compactMap(URL.init(string:)) ?? urls
    }

    /// Notes a copy that didn't load, so its server is raced last a while.
    func raceLost(_ url: URL) {
        guard let handle else { return }
        cq_race_lost(handle.pointer, url.absoluteString)
    }

    /// Forgets a source's unavailable directory, as if it were deleted: its
    /// copies go, for every device.
    func removeUnavailable(_ source: String, _ dir: String) { checkAndReload { cq_remove_unavailable($0, source, dir) } }

    /// Removes another of this person's devices from the library: its later
    /// writes are refused, and it's served no more.
    func removeDevice(_ key: String) { checkAndReload { cq_remove_device($0, key) } }

    /// Takes in a device just paired: names it as it advertised itself, or
    /// as its host is named if that's generic (until it names itself), so
    /// it's among its person's devices at once.
    private func welcome(_ paired: Paired, from device: NearbyDevice) {
        if let name = device.deviceName {
            check { cq_name($0, paired.device, paired.person, name) }
        }
        reloadSoon()
    }

    // Names and devices.

    /// Names this person, for every device to show in place of keys, and
    /// advertises the new name.
    func setPersonName(_ name: String) { setName(name) { cq_set_person_name($0, $1) } }

    /// As `setPersonName`, this device.
    func setDeviceName(_ name: String) { setName(name) { cq_set_device_name($0, $1) } }

    private func setName(_ name: String, by set: @escaping (OpaquePointer, String) -> Int32) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checkAndReload { set($0, trimmed) }
        if servingPort != nil { serve() }
    }

    /// What this device names itself as, told `name` by its platform: that,
    /// unless it's generic ("iPhone", as iOS tells apps); then its host's, as
    /// other devices show it; else nil (see the core's `cq_shown_name`).
    func shownName(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return decode(String?.self) { cq_shown_name($0, name, ProcessInfo.processInfo.hostName) } ?? nil
    }

    /// Devices found nearby (listening for 2 seconds), and any added by
    /// address with the command-line app's.
    func nearby() async -> [NearbyDevice] {
        decoded([NearbyDevice].self, await apart { coreData(cq_nearby($0)) } ?? nil) ?? []
    }
}
