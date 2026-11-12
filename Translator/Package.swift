// swift-tools-version:6.0
import PackageDescription

// The translation helper. Kept apart from the browser: MLX needs Metal shaders, which only
// `xcodebuild` compiles, and the model's memory stays in this process, outside the tabs' budget.
let package = Package(
    name: "FeatherTranslator",
    platforms: [.macOS(.v14)],
    dependencies: [
        // hunyuan_v1_dense (Hy-MT2) support checked at this version, as in AITranslate.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        .executableTarget(
            name: "FeatherTranslator",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
