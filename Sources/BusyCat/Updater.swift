import Foundation

/// Lightweight update check: ask the GitHub Releases API for the latest tag and
/// compare it to the running version. No signing, no Sparkle framework — just a
/// hint in the menu. Distribution stays manual: download the DMG or rebuild from
/// source.
enum Updater {
    enum CheckResult: Equatable, Sendable {
        case updateAvailable(String)
        case upToDate
        case failed
    }

    static let repo = "mangomandu/busycat"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// Running version from CFBundleShortVersionString (e.g. "1.0").
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private struct Version: Comparable {
        enum Identifier: Comparable {
            case number(Int)
            case text(String)

            static func < (lhs: Identifier, rhs: Identifier) -> Bool {
                switch (lhs, rhs) {
                case (.number(let a), .number(let b)): return a < b
                case (.number, .text): return true
                case (.text, .number): return false
                case (.text(let a), .text(let b)): return a < b
                }
            }
        }

        let core: [Int]
        let prerelease: [Identifier]?

        init?(_ raw: String) {
            let buildSplit = raw.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            guard !buildSplit[0].isEmpty, buildSplit.count <= 2 else { return nil }
            if buildSplit.count == 2,
               !Self.validDotIdentifiers(buildSplit[1], numericLeadingZerosAllowed: true) {
                return nil
            }
            let versionSplit = buildSplit[0].split(
                separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let components = versionSplit[0].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(components.count),
                  components.allSatisfy(Self.validCoreComponent),
                  components.allSatisfy({ Int($0) != nil })
            else { return nil }
            var normalizedCore = components.compactMap { Int($0) }
            while normalizedCore.count > 1, normalizedCore.last == 0 {
                normalizedCore.removeLast()
            }
            core = normalizedCore

            if versionSplit.count == 2 {
                let identifiers = versionSplit[1].split(separator: ".", omittingEmptySubsequences: false)
                guard Self.validDotIdentifiers(
                    versionSplit[1], numericLeadingZerosAllowed: false)
                else { return nil }
                var parsed: [Identifier] = []
                for part in identifiers {
                    if Self.isASCIINumber(part) {
                        guard let number = Int(part) else { return nil }
                        parsed.append(.number(number))
                    } else {
                        parsed.append(.text(String(part)))
                    }
                }
                prerelease = parsed
            } else {
                prerelease = nil
            }
        }

        private static func validCoreComponent(_ part: Substring) -> Bool {
            isASCIINumber(part) && (part == "0" || !part.hasPrefix("0"))
        }

        private static func validDotIdentifiers(
            _ raw: Substring,
            numericLeadingZerosAllowed: Bool
        ) -> Bool {
            let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return false }
            return parts.allSatisfy { part in
                guard !part.isEmpty, part.utf8.allSatisfy(isIdentifierByte) else { return false }
                return numericLeadingZerosAllowed
                    || !isASCIINumber(part)
                    || part == "0"
                    || !part.hasPrefix("0")
            }
        }

        private static func isASCIINumber(_ part: Substring) -> Bool {
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
        }

        private static func isIdentifierByte(_ byte: UInt8) -> Bool {
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.core.count, rhs.core.count)
            for index in 0..<count {
                let a = index < lhs.core.count ? lhs.core[index] : 0
                let b = index < rhs.core.count ? rhs.core[index] : 0
                if a != b { return a < b }
            }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil): return false
            case (.some, nil): return true
            case (nil, .some): return false
            case (.some(let a), .some(let b)):
                for index in 0..<min(a.count, b.count) where a[index] != b[index] {
                    return a[index] < b[index]
                }
                return a.count < b.count
            }
        }
    }

    /// Semantic version comparison with optional minor/patch components.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let candidate = Version(a), let current = Version(b) else { return false }
        return candidate > current
    }

    static func interpretLatestRelease(
        statusCode: Int?, data: Data?, currentVersion: String
    ) -> CheckResult {
        guard let statusCode, (200..<300).contains(statusCode), let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tag = obj["tag_name"] as? String
        else { return .failed }

        if tag.first?.lowercased() == "v" { tag.removeFirst() }
        guard let candidate = Version(tag), let current = Version(currentVersion) else { return .failed }
        return candidate > current ? .updateAvailable(tag) : .upToDate
    }

    /// Fetch the latest release tag and distinguish a successful no-update result
    /// from network, HTTP, and response-decoding failures.
    static func check(completion: @escaping @MainActor @Sendable (CheckResult) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let runningVersion = currentVersion
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BusyCat/\(runningVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let result = error == nil
                ? interpretLatestRelease(statusCode: statusCode, data: data,
                                         currentVersion: runningVersion)
                : .failed
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
