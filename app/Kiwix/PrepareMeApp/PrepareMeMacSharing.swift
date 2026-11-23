// This file is part of PrepareMe, a local build of Kiwix for one household's phones (build plan phase 4).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import Foundation
import PrepareMeShared
import Security

/// Unlisted plan, phase 4 (decision 4): the Mac's barcode keys on an adult's paired device, kept in the Keychain on
/// this device only and preferred to any built into the app, so a phone build needs none. Fetched at most once a day
/// after a good look at the Mac's inventory; the Mac's `{}` removes them, an older Mac's 404 keeps what's held, a
/// child's device, a new pairing and unpairing remove them. Never logged or shown: Settings says only which kind is used.
enum MacLookupKeys {
    private static let checkedKey = "PrepareMe.lookupKeysChecked"
    private static let account = "lookup-keys"

    /// The keys held, or nil (none held, or the Keychain locked before the first unlock).
    static var held: LookupKeys? {
        var query = self.query()
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
              let keys = try? LookupKeys.read(data), keys != LookupKeys() else { return nil }
        return keys
    }

    static func keep(_ keys: LookupKeys) {
        SecItemDelete(query() as CFDictionary)
        guard keys != LookupKeys() else { return }
        var add = query()
        add[kSecValueData as String] = keys.encoded()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func forget() {
        SecItemDelete(query() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: checkedKey)
    }

    /// After a good look at the Mac: an adult's device asks for the keys once a day; a child's lets go of any held.
    static func refresh(adult: Bool, now: Date = Date()) async {
        guard adult else { return forget() }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: checkedKey) as? Date, now.timeIntervalSince(last) < 24 * 3600,
           last <= now { return }
        switch await MacLink.lookupKeys() {
        case .success(let keys):
            keep(keys)
            defaults.set(now, forKey: checkedKey)
        case .failure(.answered(404)):  // a Mac from before phase 4: what's held stays, asked again tomorrow
            defaults.set(now, forKey: checkedKey)
        case .failure: break  // not reached, or another answer: asked again at the next look
        }
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: MacLink.keychainService,
         kSecAttrAccount as String: account]
    }
}

/// Unlisted plan, phase 4 (decision 6; owner, 2026-11-22, by click: "Ask once, switch in Settings"): whether this
/// device tells the Mac its free space. Apple's reason for reading it (85F4.1) allows sending it to the person's other
/// device only with their clear yes, so until a yes the room report carries 0 and 0 (PhoneStorage.shared) and the
/// Mac's Devices list says it doesn't share. Asked once, on the first launch while paired; Settings has the switch.
enum RoomSharing {
    static let key = "PrepareMe.shareRoom", askedKey = "PrepareMe.shareRoomAsked"
    static var allowed: Bool { UserDefaults.standard.bool(forKey: key) }
    static var asked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    static func answer(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: key)
        UserDefaults.standard.set(true, forKey: askedKey)
    }

    static func question(device: String) -> String { "Show this \(device)'s free space on the Mac?" }
    static func explanation(device: String) -> String {
        "The Mac's Devices list can show how much room this \(device) has, rounded to the gigabyte, so you can tell "
            + "when a download won't fit. You can change this later in Settings."
    }
    static func switchTitle(device: String) -> String { "Show this \(device)'s free space on the Mac" }
}

#if os(iOS)
import SwiftUI

/// The once-only question, on the first time the app comes forward while paired.
struct RoomSharingAsk: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .task(id: phase) {
                if phase == .active, !RoomSharing.asked, MacLink.pairing != nil { asking = true }
            }
            .alert(RoomSharing.question(device: ThisDevice.word), isPresented: $asking) {
                Button("Show It") { RoomSharing.answer(true) }
                Button("Not Now", role: .cancel) { RoomSharing.answer(false) }
            } message: {
                Text(RoomSharing.explanation(device: ThisDevice.word))
            }
    }
}

/// Settings' section for what this device shares with the Mac and which barcode key it uses.
struct MacSharingSettings: View {
    @AppStorage(RoomSharing.key) private var shareRoom = false

    var body: some View {
        Section(pmTitle: "The Mac") {
            Toggle(RoomSharing.switchTitle(device: ThisDevice.word), isOn: Binding(get: { shareRoom }, set: {
                RoomSharing.answer($0)
            })).pmSwitch()
            Text(Self.keyLine)
                .font(.pmNote).foregroundStyle(PrepareMeColors.text2)
        }
    }

    /// Which USDA key the barcode lookup sends: the Mac's, one built into this app, or USDA's public one.
    static var keyLine: String {
        if MacLookupKeys.held != nil { return "Barcode lookups use the Mac's key." }
        let built = Bundle.main.object(forInfoDictionaryKey: ProductLookup.keyEntry) as? String
        return ProductLookup.usdaKey(built) == ProductLookup.demoKey
            ? "Barcode lookups use the free demo key (50 a day)." : "Barcode lookups use the key built into this app."
    }
}
#endif
