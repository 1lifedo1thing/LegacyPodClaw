---
title: "AI Providers"
description: "The model providers and how to set them"
weight: 2
---

LegacyPodClaw has two provider adapters. Both stream the reply and support tool calls.

- **Anthropic Messages API.** Only the Anthropic provider uses it.
- **OpenAI-compatible chat completions.** All other providers use it.

Select one provider in the app: tap the gear button, then **Model Provider > Provider**. The in-app chat, the chat channels and the gateway server use this provider. There is no automatic failover to a different provider.

The home-button overlay and the Notification Center widget always use the Anthropic provider.

## Provider list

| Provider | Default base URL | API key | Default model | Model hint |
|---|---|---|---|---|
| Anthropic | `https://api.anthropic.com` | Required | `claude-sonnet-5-5` | `claude-sonnet-5-5` |
| OpenAI | `https://api.openai.com/v1` | Required | None | `gpt-4o-mini` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | Required | None | `gemini-2.5-flash` |
| Groq | `https://api.groq.com/openai/v1` | Required | None | `llama-3.3-70b-versatile` |
| Together AI | `https://api.together.xyz/v1` | Required | None | `meta-llama/Llama-3.3-70B-Instruct-Turbo` |
| OpenRouter | `https://openrouter.ai/api/v1` | Required | None | `anthropic/claude-sonnet-5-5` |
| Mistral | `https://api.mistral.ai/v1` | Required | None | `mistral-small-latest` |
| DeepSeek | `https://api.deepseek.com/v1` | Required | None | `deepseek-chat` |
| Ollama | None. You must set it. | Not used | None | `llama3.1` |
| Custom (OpenAI-compatible) | None. You must set it. | Optional | None | `model-id` |

The model hint is the placeholder text in the **Model** field. If the default model is "None", enter a model ID in **Model**.

The suggested Anthropic model IDs are `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` and `claude-fable-5-1`.

## Set a provider

1. Open the app and tap the gear button.
2. Tap **Provider** and select a provider.
3. Tap **API Key** and enter the key. Each provider keeps its own key in the keychain.
4. Tap **Model** and enter a model ID, if the provider has no default.
5. For Ollama or Custom, tap **Base URL** and enter the server address, for example `http://192.168.1.100:11434/v1`.

## Notes

- **Google Gemini** works only through Google's OpenAI-compatible endpoint. The native `generateContent` API is not supported.
- **Ollama** runs models on a computer on your network. It needs no API key.
- **OpenAI** gets `max_completion_tokens` in place of `max_tokens`, because its reasoning models refuse `max_tokens`.
- **Generation 5 Anthropic models** always think. The app sends at least 4096 response tokens and a low or medium effort level.

## Transport

- HTTPS goes through `CPTLSClient` on wolfSSL. The system TLS stack is not used.
- Plain HTTP is allowed, for a local server such as Ollama.
- Other URL schemes are refused.
