// Copyright (C) 2026 rusconn
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, see <https://www.gnu.org/licenses/>.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct Terminal {
    private static var originalTermios = termios()

    static func enableRawMode() {
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        withUnsafeMutableBytes(of: &raw.c_cc) { ptr in
            ptr[Int(VMIN)] = 1
            ptr[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        print("\u{1b}[?25l", terminator: "") // hide cursor
    }

    static func restore() {
        print("\u{1b}[?25h", terminator: "") // show cursor
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }

    static func readKey() -> Character? {
        var buf = [UInt8](repeating: 0, count: 1)
        guard read(STDIN_FILENO, &buf, 1) == 1 else { return nil }
        return Character(UnicodeScalar(buf[0]))
    }

    enum Input { case up, down, enter, quit, other }

    static func readInputOrArrow() -> (input: Input, isArrow: Bool) {
        guard let ch = readKey() else { return (.other, false) }
        if ch == "\n" || ch == "\r" { return (.enter, false) }
        if ch == "q" { return (.quit, false) }
        if ch == "\u{1b}" {
            let next = readKey()
            if next == "[" {
                guard let dir = readKey() else { return (.other, false) }
                if dir == "A" { return (.up, true) }
                if dir == "B" { return (.down, true) }
            }
            return (.other, false)
        }
        return (.other, false)
    }
}
