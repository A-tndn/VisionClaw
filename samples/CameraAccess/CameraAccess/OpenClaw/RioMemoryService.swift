// samples/CameraAccess/CameraAccess/OpenClaw/RioMemoryService.swift
//
// Direct HTTP client to the Rio cross-surface memory backbone (FastAPI service
// on the VPS, port 8088). Bypasses OpenClaw — every Rio surface (Claude Code,
// Telegram, glasses, web) writes to and reads from the same store.

import Foundation

@MainActor
final class RioMemoryService {
  static let shared = RioMemoryService()

  private let session: URLSession

  private init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15
    self.session = URLSession(configuration: config)
  }

  private var baseURL: String { SettingsManager.shared.rioMemoryURL }
  private var apiKey: String { SettingsManager.shared.rioMemoryAPIKey }

  var isConfigured: Bool {
    return !baseURL.isEmpty && !apiKey.isEmpty
      && baseURL != "YOUR_RIO_MEMORY_URL"
      && apiKey != "YOUR_RIO_MEMORY_API_KEY"
  }

  // MARK: - Recall (semantic search)

  func recall(query: String, limit: Int = 5, type: String? = nil) async -> ToolResult {
    guard isConfigured else {
      return .failure("rio-memory not configured. Add the URL and API key in Settings.")
    }
    guard var components = URLComponents(string: "\(baseURL)/memory/recall") else {
      return .failure("Invalid rio-memory URL")
    }
    var items: [URLQueryItem] = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let type, !type.isEmpty {
      items.append(URLQueryItem(name: "type", value: type))
    }
    components.queryItems = items
    guard let url = components.url else { return .failure("Invalid rio-memory URL") }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
        NSLog("[RioMemory] recall HTTP %d %@", code, String(body))
        return .failure("rio-memory recall failed (HTTP \(code))")
      }
      guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return .failure("rio-memory recall: bad response shape")
      }
      if arr.isEmpty {
        return .success("No relevant memories found for that query.")
      }
      let lines = arr.prefix(max(1, limit)).enumerated().map { (i, m) -> String in
        let name = (m["name"] as? String) ?? "—"
        let bodyText = (m["body"] as? String) ?? ""
        let trimmed = String(bodyText.prefix(280))
        let sim = (m["similarity"] as? Double).map { String(format: "%.2f", $0) } ?? "—"
        return "[\(i + 1)] \(name) (sim \(sim))\n\(trimmed)"
      }.joined(separator: "\n\n")
      return .success(lines)
    } catch {
      NSLog("[RioMemory] recall err: %@", error.localizedDescription)
      return .failure("rio-memory recall: \(error.localizedDescription)")
    }
  }

  // MARK: - Remember (upsert)

  func remember(name: String, type: String, body: String, description: String?) async -> ToolResult {
    guard isConfigured else {
      return .failure("rio-memory not configured. Add the URL and API key in Settings.")
    }
    let validTypes: Set<String> = ["user", "feedback", "project", "reference", "log"]
    guard validTypes.contains(type) else {
      return .failure("Invalid type '\(type)'. Use one of: \(validTypes.sorted().joined(separator: ", ")).")
    }
    guard let url = URL(string: "\(baseURL)/memory") else {
      return .failure("Invalid rio-memory URL")
    }

    var bodyDict: [String: Any] = [
      "name": name,
      "type": type,
      "body": body,
      "surfaces": ["glasses"],
    ]
    if let description, !description.isEmpty {
      bodyDict["description"] = description
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
    } catch {
      return .failure("rio-memory remember: bad payload — \(error.localizedDescription)")
    }

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
        NSLog("[RioMemory] remember HTTP %d %@", code, String(body))
        return .failure("rio-memory remember failed (HTTP \(code))")
      }
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let id = (json?["id"] as? Int).map(String.init) ?? "?"
      return .success("Saved memory '\(name)' (id \(id)).")
    } catch {
      NSLog("[RioMemory] remember err: %@", error.localizedDescription)
      return .failure("rio-memory remember: \(error.localizedDescription)")
    }
  }
}
