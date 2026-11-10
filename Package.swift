// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TotonoErrorReporting",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "TotonoErrorReporting", targets: ["TotonoErrorReporting"])],
    dependencies: [.package(url: "https://github.com/kstenerud/KSCrash.git", exact: "2.6.1")],
    targets: [.target(
        name: "TotonoErrorReporting",
        dependencies: [.product(name: "Recording", package: "KSCrash")]
    )]
)
