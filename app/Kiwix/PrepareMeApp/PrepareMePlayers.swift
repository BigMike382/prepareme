// This file is part of PrepareMe, a local build of Kiwix for one household's phones and Mac (players-and-scoreboard
// plan, stage 2: the household's players).
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.

import PrepareMeShared
import SwiftUI

/// A player's mark: the nickname's first letter on the player's color, so no player is told apart by color alone.
struct PlayerChip: View {
    let player: Player
    var body: some View {
        Text(player.letter)
            .font(.pmHeadline)
            .foregroundStyle(PrepareMeColors.onPlayer)
            .frame(width: 26, height: 26)
            .background(Circle().fill(PrepareMeColors.player(player.color)))
            .accessibilityHidden(true)  // the row's nickname says who; the color is said with it
    }
}

#if os(macOS)
/// The Mac's player list (choice A8: only the Mac adds, renames, recolors and retires): `players.json` in the app's
/// own folder beside the game saves, and after every change, and once a launch, the copy the service hands to every
/// paired device (`phone-players.json` in the inventory folder). Nicknames never reach a log.
@MainActor
final class PrepareMePlayers: ObservableObject {
    static let shared = PrepareMePlayers()

    @Published private(set) var list: PlayerList
    /// The last change's refusal, in plain words; nil once a change goes through.
    @Published private(set) var problem: String?

    private init() {
        #if PREPAREME_CHECK
        Self.seedCheck()
        #endif
        list = PlayerList.load(PrepareMeGameSaves.folder)
        if list.setAside != nil {
            problem = "PrepareMe couldn't read its list of players, so it was set aside and the list started empty."
        } else if list.blocked {
            problem = PlayerList.Problem.blocked.rawValue
        }
    }

    /// Once a launch: the devices' copy written again, so a deleted or older one is replaced.
    func launch() { writeCopy() }

    /// A change made, saved and handed on; refused, nothing changes and the reason shows.
    func change(_ edit: (inout PlayerList) throws -> Void) {
        var next = list
        do {
            try edit(&next)
            try next.save(PrepareMeGameSaves.folder)
            list = next
            problem = nil
            writeCopy()
        } catch let why as PlayerList.Problem {
            problem = why.rawValue
        } catch {
            problem = "PrepareMe couldn't save the list of players."
        }
    }

    private func writeCopy() {
        guard !list.blocked, let folder = InventoryModel.folder else { return }
        if (try? list.save(folder, as: PlayerList.phoneFileName)) == nil {
            problem = "PrepareMe couldn't write the devices' copy of the list."
        }
    }

    #if PREPAREME_CHECK
    /// The check build only: PREPAREME_CHECK_PLAYERS=<a players.json inside the check home> starts the check from a
    /// made-up household, copied over the check build's own list.
    private static func seedCheck() {
        guard let path = ProcessInfo.processInfo.environment["PREPAREME_CHECK_PLAYERS"],
              let home = PrepareMeHome.url, path.hasPrefix(home.path),
              let found = PlayerList.read(FileManager.default.contents(atPath: path)) else { return }
        try? found.save(PrepareMeGameSaves.folder)
    }
    #endif
}

/// Settings' Players tab (players plan, stage 2): the household's players, each a chip, a nickname and a color, with
/// Rename…, its color and Retire; the retired below with Bring Back; and Add Player. A right-click on a row holds the
/// same commands (docs/design/menus.md).
struct PrepareMePlayersSettings: View {
    @ObservedObject private var players = PrepareMePlayers.shared
    @State private var nickname = ""
    @State private var color = PlayerColor.violet
    @State private var renaming: Player?
    @State private var newName = ""

    var body: some View {
        let list = players.list
        PMForm {
            Section(pmTitle: "Players") {
                Text("Who plays the games. Each paired device gets this list when it's home, and a game asks who is "
                     + "playing. Use nicknames, never full names. Up to \(PlayerList.most) players.")
                    .foregroundStyle(PrepareMeColors.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if list.active.isEmpty {
                    Text("No players yet.").foregroundStyle(PrepareMeColors.text2)
                }
                ForEach(list.active) { row($0) }
                HStack(spacing: 10) {
                    TextField("Nickname", text: $nickname, prompt: Text("Nickname"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)  // a box to type in: a grouped form's fields show none by default
                        .frame(maxWidth: 200)
                        .onSubmit(add)
                    Picker("Color", selection: $color) {
                        ForEach(PlayerColor.allCases, id: \.self) { Text($0.word).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button("Add Player", action: add)
                        .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty
                                  || list.active.count >= PlayerList.most)
                    Spacer()
                }
                if let problem = players.problem {
                    Text(problem).foregroundStyle(PrepareMeColors.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            let retired = list.players.filter(\.retired)
            if !retired.isEmpty {
                Section(pmTitle: "Retired") {
                    Text("Kept so their games still count. Bring a player back to show them in the games again.")
                        .foregroundStyle(PrepareMeColors.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(retired) { player in
                        HStack(spacing: 10) {
                            PlayerChip(player: player).opacity(0.6)
                            Text(player.name).foregroundStyle(PrepareMeColors.text2)
                            Spacer()
                            Button("Bring Back") { players.change { try $0.retire(player.id, false) } }
                        }
                        .accessibilityElement(children: .combine)
                        .contextMenu { Button("Bring Back") { players.change { try $0.retire(player.id, false) } } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil },
                                                                     set: { if !$0 { renaming = nil } })) {
            TextField("Nickname", text: $newName)
            Button("Rename") {
                if let id = renaming?.id { players.change { try $0.rename(id, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ player: Player) -> some View {
        HStack(spacing: 10) {
            PlayerChip(player: player)
            Text(player.name)
            Spacer()
            Picker("Color for \(player.name)", selection: Binding(get: { player.color }, set: { choice in
                players.change { try $0.recolor(player.id, to: choice) }
            })) {
                ForEach(PlayerColor.allCases, id: \.self) { Text($0.word).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            Button("Rename…") { startRename(player) }
            Button("Retire") { players.change { try $0.retire(player.id) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(player.name), \(player.color.word)")
        .contextMenu {
            Button("Rename…") { startRename(player) }
            Button("Retire") { players.change { try $0.retire(player.id) } }
        }
    }

    private func startRename(_ player: Player) {
        newName = player.name
        renaming = player
    }

    private func add() {
        let typed = nickname
        players.change { try $0.add(typed, color: color) }
        if players.problem == nil { nickname = "" }
    }
}
#endif
