// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AltyaziTR",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "AltyaziCore", targets: ["AltyaziCore"]),
        .library(name: "RemotePlayKit", targets: ["RemotePlayKit"]),
    ],
    dependencies: [
        // chiaki'nin şifreleme için gerek duyduğu OpenSSL (hazır derlenmiş, iOS + macOS).
        .package(url: "https://github.com/krzyzanowskim/OpenSSL-Package.git", from: "3.6.0"),
    ],
    targets: [
        // Yazı okuma, altyazı sabitleme, TV'ye gönderen sunucu.
        .target(name: "AltyaziCore"),

        // chiaki-ng Remote Play kütüphanesi (AGPL-3.0). scripts/vendor-chiaki.sh ile kopyalanır.
        .target(
            name: "CChiaki",
            dependencies: [.product(name: "OpenSSL", package: "OpenSSL-Package")],
            exclude: ["licenses"],
            cSettings: [
                .headerSearchPath("shim"),
                .headerSearchPath("chiaki"),
                .headerSearchPath("proto"),
                .headerSearchPath("nanopb"),
                .headerSearchPath("jerasure"),
                .headerSearchPath("gf-complete"),
                .define("PB_C99_STATIC_ASSERT"),
            ]
        ),

        // PS5'i bulma, eşleşme, oturum ve görüntü çözme (Swift).
        .target(name: "RemotePlayKit", dependencies: ["CChiaki"]),

        .executableTarget(name: "altyazi-mac", dependencies: ["AltyaziCore", "RemotePlayKit"]),
        .testTarget(name: "AltyaziCoreTests", dependencies: ["AltyaziCore"]),
        .testTarget(name: "RemotePlayKitTests", dependencies: ["AltyaziCore", "RemotePlayKit"]),
    ]
)
