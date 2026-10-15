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

## The chat

**Scripted pi**:
The chat's pi as tests give it: it answers the chat's commands from a table and says only what the test tells it to, replaying lines a real pi once said, so a chat's asks, pauses, stops and lines are checked without pi or a provider. It stands where the chat's pi stands; a fake pi stands where pi itself does.
_Avoid_: mock chat, stub agent

**Settled**:
pi has finished with the person's message: every step done or stopped, nothing more coming until the next message. The chat then stops being busy, refuses any act still waiting for an answer, and unmarks the tabs it acted on.
_Avoid_: done, idle, finished (a step finishes; a message settles)

## The chat's browser tools

**Browser tool**:
One thing the chat's agent can do in the browser — list the tabs, read a page, click, type, open a tab — declared once with its name, its kind and what it does.
_Avoid_: agent tool, action, command

**Catalogue**:
The full set of browser tools the agent is given; nothing outside it can be called.
_Avoid_: registry, tool list

**Kind**:
Whether a browser tool reads (changes nothing), shows (changes only what the person sees — the tab in front, the scroll) or acts (changes a page or the tabs).

**Act**:
What an acting browser tool would do, worded for the person ("click “Sign in” on example.com"), before it is done.

**Ask**:
The question put to the person before an act, which they can allow once, for the chat, always for the site, or deny. Skipped when the chat acts without asking or the site is already allowed.
_Avoid_: permission prompt, confirm

**Mark**:
The sign on a tab's row and page that the agent is acting in it, until the agent settles.

**Gather**:
Putting a tab the agent opened into the chat's own tab group, when tab groups are on.

## The tab row

**Tab row**:
The tabs of one space in one window, in order, with their groups, pairs and pins. ⌘1–9, ⌃Tab and the extensions' tab indexes all read it, so its order is the order on screen. Code: `TabRow`.

**Group**:
A named, foldable section of ordinary tabs. A tab is in at most one; a group lasts as long as it has a tab in it. Groups keep their own order, and with groups turned on the row is shown pins first, then each group's tabs in the groups' order, then the tabs in none. Code: `TabGroup`.

**Pair**:
Two pages shown side by side under Split View, sharing one place in the row. Its pages stand next to each other, in one group or none, and neither is a pin. Code: `TabSplit` (shaped as a list, for more pages later).

**Pin**:
A tab kept at the head of the row, the same in every window of its space, shown by one letter. A pin is a **square** or a **pinned row** (Arc's pinned list, under the squares); the squares come first. A pin is never in a group or a pair. Code: `Tab.pin`, and `Tab.listed` for a pinned row.

**Space**:
A separate set of tabs with its own row, switched with ⌃1–9.

**Parked row**:
A space's row while another space is on screen in the same window: kept in memory as it was, pages and all. Code: `Parked`.

## Extensions

**Extension worker**:
An extension's background service worker (or, for an older extension, its background page), which WebKit starts and stops on its own. `ExtensionWorkers` knows whether each one runs.

**Kept registration**:
The service-worker registration WebKit keeps for an extension from one launch, or one run of its network process, to the next. WebKit takes it up again when the extension loads but starts no worker for it, so Search clears them all at launch.

**Dead worker**:
An extension worker that WebKit believes it has, but that doesn't run. `ExtensionWorkers` knows one by three signs: asked to start, it didn't say it started (the shim's `background.started`) within a while; WebKit reported that it failed to start; or WebKit's network process started again, which leaves every worker dead. A worker WebKit unloaded after half a minute idle is not dead; WebKit starts it again for the next event.

**Revive**:
What brings a dead worker back. Every registration is cleared, since WebKit can't clear one extension's alone, and every extension with a worker is unloaded and loaded again, its popup and side panels reopened. At most once a minute.
