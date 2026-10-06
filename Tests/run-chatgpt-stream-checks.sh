#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/hestrel-stream-checks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/Sources/StreamAdapter" "$check_dir/Tests/StreamAdapterTests"
cp "$repo_root/hestrel-ios/Core/Clients/LLM/Services/ChatGPTSearchStreamMiddleware.swift" "$check_dir/Sources/StreamAdapter/"
cp "$repo_root/hestrel-ios/Core/Clients/LLM/Services/ChatGPTStreamOutput.swift" "$check_dir/Sources/StreamAdapter/"
cp "$repo_root/hestrel-ios/Core/Models/ToolCall.swift" "$repo_root/hestrel-ios/Core/Models/JSONValue.swift" "$check_dir/Sources/StreamAdapter/"
for source in Provider ProviderKind ChatModel ModelCatalog LoadStatus GoogleConnection ToolCatalog MCPServer Connector; do
    cp "$repo_root/hestrel-ios/Core/Models/$source.swift" "$check_dir/Sources/StreamAdapter/"
done
cp "$repo_root/hestrel-ios/Core/Extensions/String+Trimming.swift" "$check_dir/Sources/StreamAdapter/"
cp "$repo_root/hestrel-ios/Core/Clients/Google/GoogleTool.swift" "$check_dir/Sources/StreamAdapter/"
cp "$repo_root/Tests/GoogleToolTests.swift" "$check_dir/Tests/StreamAdapterTests/"
cp "$repo_root/Tests/ModelSelectionTests.swift" "$check_dir/Tests/StreamAdapterTests/"
cp "$repo_root/Tests/ChatGPTStreamOutputTests.swift" "$check_dir/Tests/StreamAdapterTests/"
cat > "$check_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "StreamAdapter", platforms: [.macOS(.v14)], dependencies: [
    .package(url: "https://github.com/MacPaw/OpenAI", exact: "0.5.1"),
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", exact: "1.1.1")
], targets: [
    .target(name: "StreamAdapter", dependencies: [.product(name: "OpenAI", package: "OpenAI"), .product(name: "IdentifiedCollections", package: "swift-identified-collections")]),
    .testTarget(name: "StreamAdapterTests", dependencies: ["StreamAdapter", .product(name: "OpenAI", package: "OpenAI")])
])
PACKAGE
swift test --package-path "$check_dir" --scratch-path "${TMPDIR:-/tmp}/hestrel-stream-checks-build"
