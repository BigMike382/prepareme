// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

import SwiftUI

struct Message: View {
    private let text: String
    private let foregroundColor: Color

    init(text: String, color: Color = .secondary) {
        self.text = text
        foregroundColor = color
    }

    var body: some View {
        #if PREPAREME_APP  // PrepareMe: look 3's one look for "nothing here" (spec section 10, rule 5); an error's red
        PMState(symbol: foregroundColor == .red ? "exclamationmark.circle" : "tray", heading: text, line: "",
                kind: foregroundColor == .red ? .damaged : .info)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        kiwixBody
        #endif
    }

    private var kiwixBody: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(text).font(.title2).foregroundColor(foregroundColor)
                Spacer()
            }
            Spacer()
        }
    }
}

struct Message_Previews: PreviewProvider {
    static var previews: some View {
        Message(text: "There is nothing to see")
            .frame(width: 250, height: 200)
    }
}
