import Foundation

// What a real pi (1.2.0, in RPC mode, with Search's flags and extension)
// said in one session, trimmed of usage and cost: the lines the scripted pi
// replays, so the chat is tested against pi's own shapes.
enum PiTranscripts {
    /// browser_tabs, then browser_open refused by the person, then an answer.
    static let toolTurn = #"""
{"type": "message_start", "message": {"role": "system", "content": ""}}
{"type": "message_start", "message": {"role": "user", "content": [{"type": "text", "text": "<browser>\nThe tab in front: “Example” — https://example.com/ (tab 1a2b3c4d)\n</browser>\n\nCall browser_tabs, then browser_open https://example.org in the background. Then tell me in five words what happened."}]}}
{"type": "message_end", "message": {"role": "user", "content": [{"type": "text", "text": "<browser>\nThe tab in front: “Example” — https://example.com/ (tab 1a2b3c4d)\n</browser>\n\nCall browser_tabs, then browser_open https://example.org in the background. Then tell me in five words what happened."}]}}
{"type": "message_start", "message": {"role": "assistant", "content": [{"type": "text", "text": "I"}], "stopReason": "pending"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_start", "contentIndex": 0}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "I"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "'ll"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": " check"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": " the"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": " tabs"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": " first"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "toolcall_start", "contentIndex": 1, "id": "call_zr6nj6xc", "toolName": "browser_tabs"}}
{"type": "message_update", "assistantMessageEvent": {"type": "toolcall_delta", "contentIndex": 1, "delta": "{}"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_end", "contentIndex": 0, "content": "I'll check the tabs first."}}
{"type": "message_update", "assistantMessageEvent": {"type": "toolcall_end", "contentIndex": 1}}
{"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "I'll check the tabs first."}, {"type": "toolCall", "id": "call_zr6nj6xc", "name": "browser_tabs", "arguments": {}}], "stopReason": "toolUse", "responseId": "chatcmpl-732", "rawStopReason": "tool_calls", "durationMs": 576, "thinkingLevel": "low"}}
{"type": "tool_execution_start", "toolCallId": "call_zr6nj6xc", "toolName": "browser_tabs", "args": {}}
{"type": "tool_execution_end", "toolCallId": "call_zr6nj6xc", "toolName": "browser_tabs", "result": {"content": [{"type": "text", "text": "[1a2b3c4d] Example — https://example.com/  (in front)"}], "details": {"summary": "Looked at 1 tab"}}, "isError": false, "durationMs": 2}
{"type": "message_start", "message": {"role": "toolResult", "toolCallId": "call_zr6nj6xc", "toolName": "browser_tabs", "content": [{"type": "text", "text": "[1a2b3c4d] Example — https://example.com/  (in front)"}], "details": {"summary": "Looked at 1 tab"}, "isError": false, "durationMs": 2}}
{"type": "message_end", "message": {"role": "toolResult", "toolCallId": "call_zr6nj6xc", "toolName": "browser_tabs", "content": [{"type": "text", "text": "[1a2b3c4d] Example — https://example.com/  (in front)"}], "details": {"summary": "Looked at 1 tab"}, "isError": false, "durationMs": 2}}
{"type": "message_start", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "Now"}], "stopReason": "pending"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_start", "contentIndex": 0}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "Now"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " open"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " https"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "://"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "example"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": ".org"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " in"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " background"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "toolcall_start", "contentIndex": 1, "id": "call_axytrn0r", "toolName": "browser_open"}}
{"type": "message_update", "assistantMessageEvent": {"type": "toolcall_delta", "contentIndex": 1, "delta": "{\"url\":\"https://example.org\",\"background\":true}"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_end", "contentIndex": 0, "content": "Now open https://example.org in background."}}
{"type": "message_update", "assistantMessageEvent": {"type": "toolcall_end", "contentIndex": 1}}
{"type": "message_end", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "Now open https://example.org in background."}, {"type": "toolCall", "id": "call_axytrn0r", "name": "browser_open", "arguments": {"url": "https://example.org", "background": true}}], "stopReason": "toolUse", "responseId": "chatcmpl-581", "rawStopReason": "tool_calls", "durationMs": 645, "thinkingLevel": "low"}}
{"type": "tool_execution_start", "toolCallId": "call_axytrn0r", "toolName": "browser_open", "args": {"url": "https://example.org", "background": true}}
{"type": "tool_execution_end", "toolCallId": "call_axytrn0r", "toolName": "browser_open", "result": {"content": [{"type": "text", "text": "The person didn't allow that. Stop and ask them what to do; don't try another way around it."}], "details": {}}, "isError": true, "durationMs": 1}
{"type": "message_start", "message": {"role": "toolResult", "toolCallId": "call_axytrn0r", "toolName": "browser_open", "content": [{"type": "text", "text": "The person didn't allow that. Stop and ask them what to do; don't try another way around it."}], "details": {}, "isError": true, "durationMs": 1}}
{"type": "message_end", "message": {"role": "toolResult", "toolCallId": "call_axytrn0r", "toolName": "browser_open", "content": [{"type": "text", "text": "The person didn't allow that. Stop and ask them what to do; don't try another way around it."}], "details": {}, "isError": true, "durationMs": 1}}
{"type": "message_start", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "The"}], "stopReason": "pending"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_start", "contentIndex": 0}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "The"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " open"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " was"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " refused"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " Stop"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " and"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " ask"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "\n\nFive"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " words"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " about"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " what"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " happened"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_start", "contentIndex": 1}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "Opening"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " example"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": ".org"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " was"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " declined"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": ","}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " so"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " nothing"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " changed"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "\n\nFive"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " words"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": ":"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " **"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "Opening"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " was"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " refused"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": ";"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " Example"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " still"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " open"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": ".**"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "\n\nWant"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " me"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " to"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " try"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " again"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": ","}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " or"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " open"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " it"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " in"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " front"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " instead"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "?"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_end", "contentIndex": 0, "content": "The open was refused. Stop and ask.\n\nFive words about what happened."}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_end", "contentIndex": 1, "content": "Opening example.org was declined, so nothing changed.\n\nFive words: **Opening was refused; Example still open.**\n\nWant me to try again, or open it in front instead?"}}
{"type": "message_end", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "The open was refused. Stop and ask.\n\nFive words about what happened."}, {"type": "text", "text": "Opening example.org was declined, so nothing changed.\n\nFive words: **Opening was refused; Example still open.**\n\nWant me to try again, or open it in front instead?"}], "stopReason": "stop", "responseId": "chatcmpl-771", "rawStopReason": "stop", "durationMs": 640, "thinkingLevel": "low"}}
{"type": "agent_settled", "aborted": false}
"""#
    /// A story stopped (abort) a few words in.
    static let abortedTurn = #"""
{"type": "session_info_changed", "name": "Capture"}
{"type": "message_start", "message": {"role": "user", "content": [{"type": "text", "text": "Write a 400-word story about a lighthouse."}]}}
{"type": "message_end", "message": {"role": "user", "content": [{"type": "text", "text": "Write a 400-word story about a lighthouse."}]}}
{"type": "message_start", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "The"}], "stopReason": "pending"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_start", "contentIndex": 0}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "The"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " user"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " asks"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " for"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " a"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " 400"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "-word"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " story"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " about"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " a"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " lighthouse"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " This"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " is"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " a"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " normal"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " request"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " —"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " write"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": " it"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "."}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_start", "contentIndex": 1}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": "The"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " lamp"}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 1, "delta": " had"}}
{"type": "message_update", "assistantMessageEvent": {"type": "thinking_end", "contentIndex": 0, "content": "The user asks for a 400-word story about a lighthouse. This is a normal request — write it."}}
{"type": "message_update", "assistantMessageEvent": {"type": "text_end", "contentIndex": 1, "content": "The lamp had"}}
{"type": "message_end", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "The user asks for a 400-word story about a lighthouse. This is a normal request — write it."}, {"type": "text", "text": "The lamp had"}], "stopReason": "aborted", "responseId": "chatcmpl-33", "errorMessage": "Request was aborted", "durationMs": 368, "thinkingLevel": "low"}}
{"type": "agent_settled", "aborted": true}
"""#
    /// `get_messages`' answer: the conversation as pi kept it, so reopening
    /// a chat can be checked against the same real session.
    static let messages = #"""
{
 "messages": [
  {
   "role": "user",
   "content": [
    {
     "type": "text",
     "text": "<browser>\nThe tab in front: “Example” — https://example.com/ (tab 1a2b3c4d)\n</browser>\n\nCall browser_tabs, then browser_open https://example.org in the background. Then tell me in five words what happened."
    }
   ]
  },
  {
   "role": "assistant",
   "content": [
    {
     "type": "text",
     "text": "I'll check the tabs first."
    },
    {
     "type": "toolCall",
     "id": "call_zr6nj6xc",
     "name": "browser_tabs",
     "arguments": {}
    }
   ],
   "stopReason": "toolUse",
   "responseId": "chatcmpl-732",
   "rawStopReason": "tool_calls",
   "thinkingLevel": "low"
  },
  {
   "role": "toolResult",
   "toolCallId": "call_zr6nj6xc",
   "toolName": "browser_tabs",
   "content": [
    {
     "type": "text",
     "text": "[1a2b3c4d] Example — https://example.com/  (in front)"
    }
   ],
   "details": {
    "summary": "Looked at 1 tab"
   },
   "isError": false
  },
  {
   "role": "assistant",
   "content": [
    {
     "type": "thinking",
     "thinking": "Now open https://example.org in background."
    },
    {
     "type": "toolCall",
     "id": "call_axytrn0r",
     "name": "browser_open",
     "arguments": {
      "url": "https://example.org",
      "background": true
     }
    }
   ],
   "stopReason": "toolUse",
   "responseId": "chatcmpl-581",
   "rawStopReason": "tool_calls",
   "thinkingLevel": "low"
  },
  {
   "role": "toolResult",
   "toolCallId": "call_axytrn0r",
   "toolName": "browser_open",
   "content": [
    {
     "type": "text",
     "text": "The person didn't allow that. Stop and ask them what to do; don't try another way around it."
    }
   ],
   "details": {},
   "isError": true
  },
  {
   "role": "assistant",
   "content": [
    {
     "type": "thinking",
     "thinking": "The open was refused. Stop and ask.\n\nFive words about what happened."
    },
    {
     "type": "text",
     "text": "Opening example.org was declined, so nothing changed.\n\nFive words: **Opening was refused; Example still open.**\n\nWant me to try again, or open it in front instead?"
    }
   ],
   "stopReason": "stop",
   "responseId": "chatcmpl-771",
   "rawStopReason": "stop",
   "thinkingLevel": "low"
  },
  {
   "role": "user",
   "content": [
    {
     "type": "text",
     "text": "Write a 400-word story about a lighthouse."
    }
   ]
  },
  {
   "role": "assistant",
   "content": [
    {
     "type": "thinking",
     "thinking": "The user asks for a 400-word story about a lighthouse. This is a normal request — write it."
    },
    {
     "type": "text",
     "text": "The lamp had"
    }
   ],
   "stopReason": "aborted",
   "responseId": "chatcmpl-33",
   "errorMessage": "Request was aborted",
   "thinkingLevel": "low"
  }
 ]
}
"""#
    /// `messages` as the dictionary a `get_messages` answer gives.
    static var messagesData: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(messages.utf8))) as? [String: Any] ?? [:]
    }

    /// The lines as event dictionaries.
    static func events(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
