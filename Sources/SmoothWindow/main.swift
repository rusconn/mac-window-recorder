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

import AppKit
import QuartzCore

let windowWidth: CGFloat = 400
let windowHeight: CGFloat = 200

class SpeedTestView: NSView {
    private var frameCount = 0
    private var startTime = CACurrentMediaTime()
    private var barX: CGFloat = 0.0

    private let textField = NSTextField(labelWithString: "")
    private let barLayer = CALayer()

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true

        self.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor

        barLayer.backgroundColor = NSColor.white.cgColor
        barLayer.frame = CGRect(x: 0, y: 0, width: 15, height: windowHeight)
        self.layer?.addSublayer(barLayer)

        textField.font = NSFont(name: "Menlo-Bold", size: 16)
        textField.textColor = NSColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        textField.backgroundColor = NSColor.black
        textField.isBezeled = false
        textField.isEditable = false
        textField.frame = CGRect(x: 10, y: windowHeight - 70, width: 150, height: 60)
        textField.wantsLayer = true
        textField.layer?.cornerRadius = 4.0
        self.addSubview(textField)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window = self.window {
            let link = window.displayLink(target: self, selector: #selector(updateFrame(_:)))
            self.displayLink = link
            self.lastTimestamp = link.timestamp
            link.add(to: .main, forMode: .default)
        } else {
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
    }

    @objc private func updateFrame(_ link: CADisplayLink) {
        frameCount += 1
        let elapsed = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        let fps = elapsed > 0 ? 1.0 / elapsed : 60.0
        let pixelsPerFrame = 180.0 / fps
        barX = (barX + pixelsPerFrame).truncatingRemainder(dividingBy: windowWidth)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.transform = CATransform3DMakeTranslation(barX, 0, 0)
        CATransaction.commit()

        let elapsedMs = Int((CACurrentMediaTime() - startTime) * 1000)
        textField.stringValue = " F: \(String(format: "%06d", frameCount))\n T: \(String(format: "%08d", elapsedMs))ms"
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Strict 60fps Native Source"
        window.contentView = SpeedTestView(frame: rect)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
