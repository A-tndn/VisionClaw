// samples/CameraAccess/CameraAccess/OpenClaw/ToolCallRouter.swift
//
// Modified from upstream: switches on call.name. `recall` and `remember`
// route to RioMemoryService (direct rio-memory HTTP). Everything else falls
// through to OpenClawBridge.delegateTask as before.

import Foundation

@MainActor
class ToolCallRouter {
  private let bridge: OpenClawBridge
  private var inFlightTasks: [String: Task<Void, Never>] = [:]
  private var consecutiveFailures = 0
  private let maxConsecutiveFailures = 3

  init(bridge: OpenClawBridge) {
    self.bridge = bridge
  }

  /// Route a tool call from Gemini. `recall`/`remember` go to rio-memory;
  /// everything else delegates to OpenClaw via the bridge.
  func handleToolCall(
    _ call: GeminiFunctionCall,
    sendResponse: @escaping ([String: Any]) -> Void
  ) {
    let callId = call.id
    let callName = call.name

    NSLog("[ToolCall] Received: %@ (id: %@) args: %@",
          callName, callId, String(describing: call.args))

    // Circuit breaker (only counts OpenClaw failures; memory ops should not trip it)
    if consecutiveFailures >= maxConsecutiveFailures && callName == "execute" {
      NSLog("[ToolCall] Circuit breaker open (%d consecutive failures), rejecting %@",
            consecutiveFailures, callId)
      let errorResult: ToolResult = .failure(
        "Tool execution is temporarily unavailable after \(consecutiveFailures) consecutive failures. " +
        "Please tell the user you cannot complete this action right now and suggest they check their OpenClaw gateway connection."
      )
      let response = buildToolResponse(callId: callId, name: callName, result: errorResult)
      sendResponse(response)
      return
    }

    let task = Task { @MainActor in
      let result: ToolResult
      switch callName {

      case "recall":
        let q = (call.args["query"] as? String) ?? ""
        let limit = (call.args["limit"] as? Int)
          ?? (call.args["limit"] as? Double).map { Int($0) }
          ?? (call.args["limit"] as? NSNumber)?.intValue
          ?? 5
        let typeFilter = call.args["type"] as? String
        if q.isEmpty {
          result = .failure("recall requires a 'query' argument")
        } else {
          result = await RioMemoryService.shared.recall(query: q, limit: limit, type: typeFilter)
        }

      case "remember":
        let name = (call.args["name"] as? String) ?? ""
        let type = (call.args["type"] as? String) ?? ""
        let body = (call.args["body"] as? String) ?? ""
        let desc = call.args["description"] as? String
        if name.isEmpty || type.isEmpty || body.isEmpty {
          result = .failure("remember requires name, type, and body")
        } else {
          result = await RioMemoryService.shared.remember(name: name, type: type, body: body, description: desc)
        }

      case "execute":
        let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
        result = await bridge.delegateTask(task: taskDesc, toolName: callName)

      default:
        result = .failure("Unknown tool '\(callName)'. Available tools: execute, recall, remember.")
      }

      guard !Task.isCancelled else {
        NSLog("[ToolCall] Task %@ was cancelled, skipping response", callId)
        return
      }

      // Only count OpenClaw failures toward the circuit breaker
      if callName == "execute" {
        switch result {
        case .success: self.consecutiveFailures = 0
        case .failure: self.consecutiveFailures += 1
        }
      }

      NSLog("[ToolCall] Result for %@ (id: %@): %@",
            callName, callId, String(describing: result))

      let response = self.buildToolResponse(callId: callId, name: callName, result: result)
      sendResponse(response)

      self.inFlightTasks.removeValue(forKey: callId)
    }

    inFlightTasks[callId] = task
  }

  /// Cancel specific in-flight tool calls (from toolCallCancellation)
  func cancelToolCalls(ids: [String]) {
    for id in ids {
      if let task = inFlightTasks[id] {
        NSLog("[ToolCall] Cancelling in-flight call: %@", id)
        task.cancel()
        inFlightTasks.removeValue(forKey: id)
      }
    }
    bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
  }

  /// Cancel all in-flight tool calls (on session stop)
  func cancelAll() {
    for (id, task) in inFlightTasks {
      NSLog("[ToolCall] Cancelling in-flight call: %@", id)
      task.cancel()
    }
    inFlightTasks.removeAll()
    consecutiveFailures = 0
  }

  // MARK: - Private

  private func buildToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    return [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }
}
