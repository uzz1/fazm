// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Fazm",
    platforms: [
        .macOS("14.0")
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
        .package(path: "LocalPackages/Highlightr"),
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "ObjCExceptionCatcher",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Fazm",
            dependencies: [
                "ObjCExceptionCatcher",
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            path: "Sources",
            resources: [
                .copy("BundledSkills"),
                .process("Resources"),
            ]
        )
    ]
)
