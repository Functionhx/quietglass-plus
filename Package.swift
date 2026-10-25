// swift-tools-version: 5.9
// Clinton Imaro was here 20/09/2026.
import PackageDescription

let package = Package(
    name: "QuietGlass",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuietGlass", targets: ["QuietGlass"])],
    targets: [
        .target(name: "ShieldCore"),
        // SFace.mlmodel is compiled into the app by build.sh. Xcode 27's SwiftPM
        // tries to generate model classes for bundled .mlmodel resources and fails.
        .executableTarget(name: "QuietGlass", dependencies: ["ShieldCore"], exclude: ["Resources/SFace.mlmodel"], resources: [
            .copy("Resources/NearbyAlert.mp3")
        ]),
        .testTarget(name: "ShieldCoreTests", dependencies: ["ShieldCore"]),
        .testTarget(name: "QuietGlassTests", dependencies: ["QuietGlass"], resources: [.copy("Fixtures")])
    ]
)
