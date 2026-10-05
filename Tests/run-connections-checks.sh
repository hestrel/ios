#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/hestrel-connections-checks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/Sources/ConnectionsAdapter" "$check_dir/Tests/ConnectionsAdapterTests"
for source in Core/Models/GoogleConnection Core/Models/JSONValue Core/Models/ToolCall Core/Clients/Google/GoogleTool Core/Clients/Google/GoogleClient Core/Extensions/Result+Async Features/Connections/ConnectionsFeature; do
    cp "$repo_root/hestrel-ios/$source.swift" "$check_dir/Sources/ConnectionsAdapter/"
done
cat > "$check_dir/Sources/ConnectionsAdapter/TestStorage.swift" <<'SWIFT'
import ComposableArchitecture
extension GoogleClient: DependencyKey {
    static let liveValue = GoogleClient()
    static let testValue = GoogleClient()
}
extension SharedKey where Self == InMemoryKey<GoogleConnection>.Default {
    static var googleConnection: Self { Self[.inMemory("testGoogle"), default: GoogleConnection()] }
}
SWIFT
cp "$repo_root/Tests/ConnectionsReducerTests.swift" "$check_dir/Tests/ConnectionsAdapterTests/"
cat > "$check_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ConnectionsAdapter", platforms: [.macOS(.v14)], dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.26.2")
], targets: [
    .target(name: "ConnectionsAdapter", dependencies: [.product(name: "ComposableArchitecture", package: "swift-composable-architecture")]),
    .testTarget(name: "ConnectionsAdapterTests", dependencies: ["ConnectionsAdapter", .product(name: "ComposableArchitecture", package: "swift-composable-architecture")])
])
PACKAGE
swift test --package-path "$check_dir" --scratch-path "${TMPDIR:-/tmp}/hestrel-connections-checks-build"
