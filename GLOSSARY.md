# Search

A macOS web browser on WebKit. Its sidebar can hold a chat with an agent (pi) that reads and acts in the person's tabs.

## Running pi

**pi**:
The person's own coding agent, a program on their login shell's path, which Search starts with its own browser tools in place of pi's.
_Avoid_: the agent binary, the CLI

**Confined**:
How every pi Search starts is run: only the tools Search gives it, and none of the person's MCP servers, skills, prompt templates, context files or themes. Their providers, models and keys stay theirs.
_Avoid_: sandboxed, restricted

**Chat's pi**:
The pi behind one chat, kept running while the chat is open and talked to a line at a time.
_Avoid_: pi process, session (a session is what pi keeps on disk)

**One-shot run**:
pi run once to its end for a single answer, away from any chat and with no tools: the pills over the chat's box, a chat's title, Sort Tabs.
_Avoid_: ask (that's the question put to the person), query, print

**Fake pi**:
A small script that stands in for pi in tests, so pi can be started, talked to and stopped without the person's pi or their tokens.
_Avoid_: mock pi, stub
