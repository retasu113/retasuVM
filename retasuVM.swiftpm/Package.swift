// swift-tools-version: 5.9

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "retasuVM",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "retasuVM",
            targets: ["AppModule"],
            bundleIdentifier: "jp.retasu.retasuVM",
            teamIdentifier: "",
            displayVersion: "0.3.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .shapes),
            accentColor: .presetColor(.green),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
