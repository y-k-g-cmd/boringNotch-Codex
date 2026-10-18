//
//  constants.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation

let productPage = URL(string: Bundle.main.object(forInfoDictionaryKey: "ForkRepositoryURL") as? String ?? "https://github.com/y-k-g-cmd/boringNotch-Codex")!
let sponsorPage = URL(string: "https://buymeacoffee.com/jfxh67wvfxq")!



/// Updates stay off until the fork's own feed and signing public key are configured.
enum ForkUpdateConfiguration {
    static var isEnabled: Bool { isEnabled(info: Bundle.main.infoDictionary ?? [:]) }

    static func isEnabled(info: [String: Any]) -> Bool {
        guard info["ForkUpdatesEnabled"] as? Bool == true,
              let repository = info["ForkRepositoryURL"] as? String,
              let repo = URL(string: repository), repo.scheme == "https", repo.host == "github.com",
              repo.user == nil, repo.password == nil, repo.port == nil, repo.query == nil, repo.fragment == nil,
              let feedString = info["SUFeedURL"] as? String, let feed = URL(string: feedString),
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else { return false }
        let parts = repo.path.split(separator: "/")
        guard parts.count == 2,
              !(parts[0].lowercased() == "theboredteam" && parts[1].lowercased() == "boring.notch") else { return false }
        return feed.scheme == "https" && feed.host?.lowercased() == "\(parts[0].lowercased()).github.io"
            && feed.path == "/\(parts[1])/appcast.xml" && feed.query == nil && feed.fragment == nil
            && feed.user == nil && feed.password == nil && feed.port == nil
    }
}
