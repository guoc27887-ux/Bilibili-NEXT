// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BiliGlass", platforms: [.macOS(.v26)], products: [.executable(name: "BiliGlass", targets: ["BiliGlass"])], dependencies: [.package(path: "Vendor/BiliKitCore")], targets: [
    .executableTarget(name: "BiliGlass", dependencies: [.product(name: "BiliModels", package: "BiliKitCore"), .product(name: "BiliNetworking", package: "BiliKitCore"), .product(name: "BiliPlayback", package: "BiliKitCore")], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "BiliGlassTests", dependencies: ["BiliGlass"])
])
