// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TotonoErrorReporting",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TotonoErrorReporting", targets: ["TotonoErrorReporting"])],
    dependencies: [
        .package(url: "https://github.com/kstenerud/KSCrash.git", exact: "2.6.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [.target(
        name: "TotonoErrorReporting",
        dependencies: [
            .product(name: "Recording", package: "KSCrash", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]
    )]
)
