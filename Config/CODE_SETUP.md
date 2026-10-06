# Code sessions

The **Code** tab runs a coding agent on your own computer, in your own projects: [Codex](https://github.com/openai/codex), [Claude Code](https://docs.claude.com/en/docs/claude-code), [OpenCode](https://opencode.ai), [pi](https://github.com/badlogic/pi-mono), and any agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP), such as Gemini CLI, Goose, Qwen Code or Hermes. Prompts go straight to the agent; no chat model sits in between. Each agent uses its own sign-in on the computer, which Hestrel never sees.

As the agent works, the session shows its messages, each command it runs (tap to see the output), each file it reads, and each file it edits (tap to see the diff).

Before the first prompt, use the composer to choose:

- **Folder:** the working folder on the computer.
- **Agent:** any of the agents installed on the computer.
- **Model:**
  - Codex models come from your ChatGPT account, the same catalog Codex uses.
  - Claude Code offers Fable, Opus, Sonnet and Haiku, each the latest model of that family.
  - Other agents list the models they can use with the accounts set up on the computer. Long lists are searchable.
  - **Default** keeps whatever the agent's own config on the computer says.
- **Effort:** how long the agent thinks.

These settings are locked after the first prompt. Follow-up prompts continue the same session.

## 1. Install the agents

Install either agent, or both, and sign in:

- **Codex:**

  ```sh
  npm install -g @openai/codex   # or: brew install codex
  codex login
  ```

- **Claude Code:** follow the [setup guide](https://docs.claude.com/en/docs/claude-code/setup), then run `claude` once to sign in.
- **Other agents:** install and sign in the way each one documents. Run each one once in a terminal to make sure it works, e.g. `opencode run "hi"` or `pi -p "hi"`.

## 2. Start Hestrel's bridge

Run the bridge from your projects folder. That folder is where sessions start when no folder is chosen. It needs Node 22 or later and has no dependencies:

```sh
cd ~/dev
node /path/to/hestrel-ios/Tools/hestrel-bridge.mjs
```

The bridge offers every agent it finds:

- **Codex.** The bridge runs one long-lived `codex app-server`, the same protocol the Codex app uses.
  - Sessions from Hestrel are ordinary Codex threads, and they resume from disk, even after the bridge restarts.
  - Sessions start with the `workspace-write` sandbox and approvals turned off. Codex can edit files only inside the working folder, and nobody has to answer approval prompts from the phone.
- **Claude Code.** The bridge runs `claude -p` in the session's folder for each prompt and streams Claude Code's progress.
  - Sessions run in `acceptEdits` permission mode with Claude Code's Bash sandbox. Edits inside the folder are accepted and shell commands run sandboxed.
  - Claude Code saves its sessions on disk, so they always resume. They go to the account in the bridge's `CLAUDE_CONFIG_DIR`, so start the bridge with the same setting you use for `claude` (for example `CLAUDE_CONFIG_DIR=~/.claude-work`).
- **pi.** The bridge runs `pi -p --mode json` for each prompt, resuming the session by ID. Effort sets pi's thinking level.
- **ACP agents.** The bridge runs one long-lived ACP process per agent. It knows `opencode acp`, `gemini --experimental-acp`, `qwen --experimental-acp`, `goose acp` and `hermes-acp`, and offers whichever are installed. Sessions resume through the agent's own session store.
  - Nobody can answer permission prompts from the phone, so the bridge allows what the agent asks for, one request at a time. Use the agent's own settings to deny or restrict anything you never want it to do.
  - To add another ACP agent, list it in `~/.hestrel/agents.json` (no app update needed):

    ```json
    [{ "id": "my-agent", "title": "My Agent", "command": ["my-agent", "--acp"] }]
    ```

Every agent other than Codex and Claude Code reports to Hestrel in one shared event format (`hestrel/event`, see `EventWriter` in the bridge), so adding one is a bridge-only change.

## 3. Pair it

The first time, the bridge shows a QR code. To pair, use either:

- **Hestrel:** go to **Code → Pair a Computer**, or **Plugins → Pair a Computer**.
- **The iPhone Camera:** scanning the code opens Hestrel.

You can also type the 8-character code shown under the QR code.

Pairing needs you to be signed in to Hestrel, because the computer becomes part of your account:

- **Every device:** each device signed in to the account lists the computer under **Plugins → Computers** and offers its agents in the Code tab. Nothing to type.
- **From anywhere:** the bridge keeps an outbound connection to Hestrel's relay, and your devices reach the computer through it, at home or away. Nothing on the computer listens on the network, and only your account's devices can reach it.

The pairing is saved in `~/.hestrel/bridge.json`, so later runs connect straight away. To manage it:

- **Re-pair**, e.g. to move the computer to another account: run the bridge with `--pair`.
- **Unpair:** remove the computer in **Plugins** (swipe left).

These environment variables change how the bridge runs:

| Variable | Effect |
| --- | --- |
| `HOST` | Also serve the local network directly, e.g. `0.0.0.0`. By default the bridge only listens on `127.0.0.1`. |
| `PORT` | The local port (default 8933). |
| `HESTREL_BRIDGE_TOKEN` | Requires that token for direct (non-relay) requests. |
| `HESTREL_RELAY=off` | Don't pair or use the relay; direct connections only. |
| `HESTREL_BRIDGE_CONFIG` | Where the pairing is kept, e.g. one file per Hestrel account. |
| `CLAUDE_PERMISSION_MODE` | Claude Code's permission mode. |
| `CODEX_BIN`, `CLAUDE_BIN` | Paths to the agents' executables. |

To keep the bridge running after you log out, wrap it in a launchd agent or run it inside `tmux`.

Because the agents are ordinary MCP tools, chat models can also call them from a normal chat with OpenAI, Ollama and OpenAI-compatible providers. Claude chats can't use them, because Anthropic's API calls MCP servers itself and would need your account's credentials.

## Continue on your computer

Once a session has started, tap its title in Hestrel and choose **Copy Resume Command**. Run the command in a terminal on the computer to pick up where you left off:

- **Codex:** `codex resume <id>`. Hestrel's Codex sessions also appear in the Codex app's thread list.
- **Claude Code:** `cd <folder> && claude --resume <id>`. Claude Code's `/resume` picker doesn't list sessions started headlessly (`claude -p`), which is how the bridge runs them, so use the command. The session is named "Hestrel: …" after its first prompt.

## Security

Anyone who can use a paired computer can run code and edit files on it as you:

- **Relay access:** only devices signed in to the Hestrel account it's paired with. The bridge never receives their credentials; the relay checks them.
- **Pairing codes** are single-use and expire after 10 minutes.
- **Unpairing:** remove a computer in Plugins and its bridge is disconnected at once.
- **Direct access** (`HOST`): anyone who can reach the port. Set `HESTREL_BRIDGE_TOKEN`, and use it only on networks you trust.

## Limits

- **Locking the phone or losing signal doesn't stop a turn.** The agent keeps working on the computer while the bridge holds on to everything it reports. When Hestrel is back, the open session reconnects and catches up exactly where it left off. If iOS closed the app in the meantime, the session rebuilds the reply when Hestrel next launches. The bridge keeps a finished turn's output for an hour; only ■ Stop ends a turn early.
- **Lost sessions.** If a session can't be resumed (its files were deleted, or the agent runs on another computer), the next prompt starts a new session in the same folder with a recap of the conversation so far.
- **Live view.** The Codex app runs its own Codex process, so it may not show a turn from Hestrel while it runs. Reopen the thread to see the latest.
- **Stop.** Stop interrupts the agent's turn. With Codex, a shell command that's already running still finishes.
