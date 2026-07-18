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

// swift-tools-version: 6.0
import PackageDescription

let packageDir = String(#filePath.dropLast("Package.swift".count))

let package = Package(
    name: "window-recorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "window-recorder",
            dependencies: ["CFFmpeg"],
            path: "Sources/WindowRecorder",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../../../vendor/ffmpeg/lib",
                ]),
            ]
        ),
        .target(
            name: "CFFmpeg",
            path: "Sources/CFFmpeg",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L\(packageDir)/vendor/ffmpeg/lib"]),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avformat"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swscale"),
            ]
        ),
    ]
)
