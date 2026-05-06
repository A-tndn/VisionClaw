// samples/CameraAccess/CameraAccess/OpenClaw/ToolCallModels.swift
//
// Modified from upstream: ToolDeclarations.allDeclarations() now includes
// `recall` and `remember` for the rio-memory bridge alongside `execute`.

import Foundation

// MARK: - Gemini Tool Call (parsed from server JSON)

struct GeminiFunctionCall {
  let id: String
  let name: String
  let args: [String: Any]
}

struct GeminiToolCall {
  let functionCalls: [GeminiFunctionCall]

  init?(json: [String: Any]) {
    guard let toolCall = json["toolCall"] as? [String: Any],
          let calls = toolCall["functionCalls"] as? [[String: Any]] else {
      return nil
    }
    self.functionCalls = calls.compactMap { call in
      guard let id = call["id"] as? String,
            let name = call["name"] as? String else { return nil }
      let args = call["args"] as? [String: Any] ?? [:]
      return GeminiFunctionCall(id: id, name: name, args: args)
    }
  }
}

// MARK: - Gemini Tool Call Cancellation

struct GeminiToolCallCancellation {
  let ids: [String]

  init?(json: [String: Any]) {
    guard let cancellation = json["toolCallCancellation"] as? [String: Any],
          let ids = cancellation["ids"] as? [String] else {
      return nil
    }
    self.ids = ids
  }
}

// MARK: - Tool Result

enum ToolResult {
  case success(String)
  case failure(String)

  var responseValue: [String: Any] {
    switch self {
    case .success(let result):
      return ["result": result]
    case .failure(let error):
      return ["error": error]
    }
  }
}

// MARK: - Tool Call Status (for UI)

enum ToolCallStatus: Equatable {
  case idle
  case executing(String)
  case completed(String)
  case failed(String, String)
  case cancelled(String)

  var displayText: String {
    switch self {
    case .idle: return ""
    case .executing(let name): return "Running: \(name)..."
    case .completed(let name): return "Done: \(name)"
    case .failed(let name, let err): return "Failed: \(name) - \(err)"
    case .cancelled(let name): return "Cancelled: \(name)"
    }
  }

  var isActive: Bool {
    if case .executing = self { return true }
    return false
  }
}

// MARK: - Tool Declarations (for Gemini setup message)

enum ToolDeclarations {

  static func allDeclarations() -> [[String: Any]] {
    return [execute, recall, remember]
  }

  static let execute: [String: Any] = [
    "name": "execute",
    "description": "Take action that goes beyond simple Q&A: send messages, search the web, control apps, place orders, manage smart home, draft and send things. For anything you can't answer purely from rio-memory or your own knowledge, use this tool.",
    "parameters": [
      "type": "object",
      "properties": [
        "task": [
          "type": "string",
          "description": "Clear, detailed description of what to do. Include all relevant context: names, content, platforms, quantities, etc."
        ]
      ],
      "required": ["task"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let recall: [String: Any] = [
    "name": "recall",
    "description": "Search Rio's persistent cross-surface memory using semantic search. Use this BEFORE answering anything that depends on past conversations, the user's projects, preferences, or facts they previously told you. Always recall first when the user references something they 'said before', 'mentioned', or any topic that may have prior context. Returns the top matching memory entries with their content.",
    "parameters": [
      "type": "object",
      "properties": [
        "query": [
          "type": "string",
          "description": "Natural language query describing what you're looking for. Examples: 'how does Ajay want me to communicate', 'RIO Coin treasury', 'session betting method', 'what's on my plate this week'."
        ],
        "limit": [
          "type": "integer",
          "description": "Max number of memory entries to return (default 5, max 10)."
        ],
        "type": [
          "type": "string",
          "description": "Optional filter by memory type. One of: user, feedback, project, reference, log."
        ]
      ],
      "required": ["query"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]

  static let remember: [String: Any] = [
    "name": "remember",
    "description": "Save a durable memory entry to Rio's cross-surface memory backbone. Use this when the user explicitly asks you to remember something OR when you observe something genuinely useful for future sessions: a preference, a fact about an ongoing project, a constraint, a reference to an external system. Avoid storing transient or session-only context. Will overwrite if the same name exists.",
    "parameters": [
      "type": "object",
      "properties": [
        "name": [
          "type": "string",
          "description": "Short unique identifier for the memory (used as primary key). Lowercase, dashed if multi-word. Examples: 'preferred-takeout-place', 'rio-coin-launch-deadline'."
        ],
        "type": [
          "type": "string",
          "description": "Type of memory. user=identity/preferences; feedback=how to behave; project=ongoing work/decisions/why; reference=pointer to external system; log=ambient observation."
        ],
        "body": [
          "type": "string",
          "description": "The memory content. Be specific; include why and how to apply if relevant. For feedback/project entries, structure with **Why:** and **How to apply:** lines."
        ],
        "description": [
          "type": "string",
          "description": "Optional one-line summary used when surfacing the memory."
        ]
      ],
      "required": ["name", "type", "body"]
    ] as [String: Any],
    "behavior": "BLOCKING"
  ]
}
