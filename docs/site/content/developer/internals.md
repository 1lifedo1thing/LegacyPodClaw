---
title: "Internals"
description: "Agent loop, providers, tool dispatcher and chat channels"
weight: 6
---

## Agent loop

`OCAgent` (`Frameworks/Agent/Agent.h`) runs one conversation:

1. It adds the user message to the context and trims the context to the token budget.
2. It sends the system prompt, the messages and the tools to the provider through `OCProviderClient`. The reply streams back.
3. If the reply has tool calls, it runs them one at a time through `OCToolDispatcher`. Then it sends the results to the model.
4. It stops after 8 rounds of tool calls, or when the reply has no tool calls.

Other details:

- `toolsEnabled` set to `NO` sends no tools to the model.
- `toolCaller` tells the dispatcher who asked: the in-app chat, a chat channel or a remote client.
- If the reply hits the token limit before its tool calls run, the agent records the calls as "not run".
- `abort` cancels the request in flight.

### Token budget

- The token estimate is the character count divided by 4.
- `compactContext` drops the oldest messages until the context fits `maxContextTokens`. It does not summarise them. It keeps the newest message, and the history always starts on a user turn.
- The app sets `maxContextTokens` and the response limit from **Max Context Tokens** (default 2048) and **Max Response Tokens** (default 512).

### Delegate

`OCAgentDelegate` has these methods:

- `agent:didProduceText:isFinal:` gives streamed text and the final text.
- `agent:didFailWithError:` reports an error.
- `agent:willInvokeTool:withParams:` and `agent:didInvokeTool:result:` report tool calls.
- `agent:didStartThinking:` and `agent:tokenUsage:output:` are optional.

### MCP client

`OCMCPClient` speaks JSON-RPC 2.0 over HTTP or HTTPS through `CPFetch`. It calls `initialize`, `tools/list` and `tools/call`. Each MCP tool needs approval. `availableTools` adds MCP tools only when their names do not clash with a registered tool.

## Providers

`Frameworks/Providers/` has the provider catalogue and the client:

- `OCProviderInfo` lists the ten providers. Each entry has a format, a default base URL, a secret key name and a model hint.
- `OCProviderClient` builds the request, streams it and parses the stream. `OCAnthropicStreamParser` reads Anthropic server-sent events. `OCOpenAIStreamParser` reads OpenAI-compatible chunks.
- HTTPS goes through `+[CPTLSClient streamRequest:...]`. Plain HTTP goes through `NSURLConnection`, for a local server such as Ollama.
- For Anthropic, the client sends the provider's content blocks back unchanged, so thinking blocks stay valid.

There is no failover between providers.

## Tool dispatcher

`OCToolDispatcher` (`Frameworks/Tools/ToolDispatcher.h`) is the one path for every tool call. `-runTool:input:caller:completion:` does these steps on the main thread:

1. It checks that the input is a JSON object that matches the tool's schema (`OCToolSchemaProblem`).
2. For `write_file`, `edit_file`, `delete_file`, `list_files` and `read_file`, it checks the path with `OCGuardrails`.
3. It asks the user in these conditions:
   - The tool has `requiresConfirmation`.
   - The caller is a chat channel.
   - The guardrails ask for approval.
   - A remote client calls a file tool.
4. It runs the handler and enforces the timeout (default 30 seconds).
5. It calls the completion once, with a string result of at most 16,384 characters.

### Tool definition

`OCToolDefinition` has these properties:

- `name`
- `toolDescription`, which goes to the model
- `inputSchema`, a JSON Schema object
- `handler`, a block that runs the tool
- `requiresConfirmation`
- `timeout`, default 30 seconds

### Guardrails

`OCGuardrails` (`Frameworks/Tools/Guardrails.h`) checks file paths only. It blocks writes to system paths and reads of secret stores. It asks for approval for writes to `/etc/` and similar paths. It has no command denylist, because the user approves each `bash` call. See [Tools](/guide/tools/) for the path lists.

## Chat channels

- Each channel conforms to `OCChannel` (`Frameworks/Channels/ChannelManager.h`). It turns platform traffic into `OCChannelMessage` objects and sends replies.
- `OCChannelManager` holds the channels and refuses a second channel with the same ID.
- `OCChannelRouter` checks the allow list, keeps one conversation for each chat and thread, and runs a separate `OCAgent` for each conversation. It keeps at most 32 conversations and 20 messages in each.
- `OCStripMarkdown` removes Markdown marks for IRC. `OCSplitText` and `OCSendPartsInOrder` send a long reply in parts, in order.
- Discord, Slack and IRC over TLS use the long-lived wolfSSL connection `CPTLSConnection`.

## Gateway server

`OCGatewayServer` (`Frameworks/Server/GatewayServer.h`) runs on `OCHTTPServer` and `OCServerWebSocket`. `OCGatewayToken` makes and stores the 256-bit access token. See [Gateway Server](/guide/gateway/).
