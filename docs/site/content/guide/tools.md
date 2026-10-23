---
title: "Tools"
description: "What the assistant can do on the device, and how you approve it"
weight: 3
---

In the app, the model can call tools on the device. Every tool call goes through one dispatcher, `OCToolDispatcher`. The dispatcher does these checks:

1. It checks the input against the tool's schema.
2. For a file tool, it checks the path against the guardrails.
3. For a risky tool, it asks you to approve the call.
4. It stops waiting for the tool after the tool's timeout. The default timeout is 30 seconds.

The home-button overlay and the Notification Center widget have no tools.

## Approval

A risky tool shows the **Allow Tool?** alert before it runs. The alert shows:

- Who asked: the assistant, a chat channel message or a remote gateway client.
- The tool name.
- The command, path and URL in full. Runs of spaces and control characters are made visible.

Tap **Allow** to run the tool. Tap **Deny** to refuse it. If you do nothing for 60 seconds, the app refuses the call. If a command or path is too long to show, the app refuses the call without an alert.

These tools always need approval:

- `bash`, `write_file`, `edit_file`, `delete_file`
- `launch_app`, `lock_device`, `open_url`
- `delete_note`, `delete_reminder`
- Every tool from an MCP server or a plugin

These calls also need approval:

- Every tool call from a chat channel conversation.
- A file tool call from a remote gateway client.
- A write, edit or delete in `/etc/`, `/Library/MobileSubstrate/` or the `com.apple.*` and LegacyPodClaw preference files.

## Tool list

### Device and time

| Tool | What it does |
|---|---|
| `get_datetime` | Gets the date, time and time zone |
| `device_info` | Gets the model, iOS version and memory |
| `device_state` | Gets the brightness, battery, Wi-Fi and similar state |
| `clipboard` | Reads or writes the clipboard |
| `calculate` | Calculates an arithmetic expression |
| `set_timer` | Schedules a local notification after a number of seconds |
| `network_info` | Lists the network interfaces and IPv4 addresses |
| `storage_info` | Shows the free and total space on `/` and `/var` |
| `process_list` | Lists up to 50 running processes |

### Shell and files

| Tool | What it does |
|---|---|
| `bash` | Runs a command with `/bin/sh` as `mobile`. The command stops after 30 seconds. The output is cut at 16 KB. |
| `list_files` | Lists a directory |
| `write_file` | Writes a file. The limit is 1 MB. |
| `edit_file` | Replaces text in a file |
| `delete_file` | Deletes a file |

`bash` has no command denylist. You approve each command.

### Web

| Tool | What it does |
|---|---|
| `http_fetch` | Gets a URL with HTTP GET. Only `http` and `https` are allowed. |
| `web_search` | Searches DuckDuckGo and returns up to 5 results |

### Memory

| Tool | What it does |
|---|---|
| `memory_store` | Saves a note with a key and tags in a SQLite full-text table |
| `memory_search` | Searches the saved notes with full-text search |

### Notes and Reminders

| Tool | What it does |
|---|---|
| `create_note`, `update_note`, `delete_note` | Changes a note in the Notes app. The tool quits Notes first. Each write is one database transaction. |
| `list_notes`, `read_note`, `search_notes` | Reads notes |
| `create_reminder`, `complete_reminder`, `delete_reminder` | Changes a reminder through EventKit |
| `list_reminders`, `list_reminder_lists`, `create_reminder_list` | Reads reminders and lists, or makes a list |

The first Reminders tool call asks for Reminders access. If you refuse, allow it in **Settings > Privacy > Reminders**.

### Messages

| Tool | What it does |
|---|---|
| `send_message` | Puts a message from "LegacyPodClaw" in the Messages app |
| `read_replies` | Reads your replies in that conversation |

### System

| Tool | What it does |
|---|---|
| `set_brightness` | Sets the screen brightness, 0.0 to 1.0 |
| `set_volume` | Sets the volume, 0.0 to 1.0 |
| `toggle_wifi` | Turns Wi-Fi on or off |
| `launch_app` | Opens an app by its URL scheme |
| `open_url` | Opens a URL |
| `lock_device` | Locks the device |
| `vibrate` | Vibrates the device |
| `post_notification` | Shows a notification banner |

### Music

| Tool | What it does |
|---|---|
| `search_music` | Searches YouTube and returns 5 results |
| `download_music` | Downloads a song through the music proxy and adds it to the Music app |
| `list_music` | Lists or searches the songs in the Music library |

See [Music Downloads](/guide/music/).

### MCP servers

Set up to two MCP server URLs in **Settings > LegacyPodClaw > Local Agent > Server 1** and **Server 2**. The app connects with JSON-RPC over HTTP or HTTPS and adds the server's tools. A server tool cannot replace a built-in tool with the same name.

### Plugins

A plugin can add tools. See [Plugin SDK](/developer/plugin-sdk/).

## Guardrails

The guardrails check the path of `write_file`, `edit_file`, `delete_file` and `list_files`. They first resolve symbolic links and `..`.

- **Blocked writes:** `/System/`, `/usr/lib/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/`, `/bin/`, `/boot/`, `/var/stash/`, `/usr/share/firmware` and `/usr/standalone`.
- **Blocked reads:** the keychain, `/var/db/`, and the Mail, Accounts, SMS, AddressBook, Cookies, Safari and CallHistory data. The LegacyPodClaw settings file is also blocked.
- **Low disk space:** a write or edit is blocked when less than 50 MB is free on `/var`.
- **Relative paths:** blocked. Use an absolute path.

## Limits

- The model can do at most 8 rounds of tool calls for one message.
- The app runs tool calls one at a time, so two approval alerts never show together.
- A tool result longer than 16,384 characters is cut.
