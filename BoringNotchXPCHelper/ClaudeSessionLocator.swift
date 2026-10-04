//
//  ClaudeSessionLocator.swift
//  BoringNotchXPCHelper
//
//  Maps a Claude Code session id (what hooks report) to the Claude desktop
//  app's own id for that session, so the notch can open the exact chat.
//

import Foundation

enum ClaudeSessionLocator {
    /// Returns the desktop app's session id ("local_…") for a Code-tab session,
    /// or nil when the session wasn't started from the desktop app (e.g. a terminal).
    static func desktopSessionId(forCLISession cliSessionId: String) -> String? {
        guard UUID(uuidString: cliSessionId) != nil else { return nil }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }

        let needle = Data(cliSessionId.utf8)
        for case let url as URL in files where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            // Cheap byte search first; only parse the file that mentions this session.
            guard let data = try? Data(contentsOf: url), data.range(of: needle) != nil,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["cliSessionId"] as? String == cliSessionId,
                  let sessionId = object["sessionId"] as? String
            else { continue }
            return sessionId
        }
        return nil
    }
}
