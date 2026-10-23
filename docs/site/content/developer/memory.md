---
title: "Memory Management"
description: "How LegacyPodClaw works on devices with 256 MB to 1 GB of RAM"
weight: 3
---

LegacyPodClaw runs on devices with 256 MB to 1 GB of RAM. The app has a memory budget of 80 MB.

## No ARC

Every target builds with `-fno-objc-arc`. The code uses manual retain and release, so each object lifetime is explicit.

- Do not use `__weak` or `weak` properties. Use `assign` and clear the pointer in `dealloc`.
- Balance each `alloc`, `copy`, `new` and `retain` with a `release` or `autorelease`.
- Put an `@autoreleasepool` around a loop that makes many temporary objects.

## Memory monitor

`OCMemoryMonitor` (`Frameworks/Memory/MemoryPool.h`) checks the app's memory use every 5 seconds. It compares the use with the 80 MB budget and reports four levels:

| Level | Use of the budget | What the app does |
|---|---|---|
| Normal | 60 % or less | Nothing |
| Warning | More than 60 % | Trims the message windows |
| Critical | More than 80 % | Trims the message windows, runs SQLite `VACUUM` and clears the URL cache |
| Terminal | More than 90 % | Also clears the agent context and the channel conversations |

A system memory warning has the same effect as the Critical level.

## Message windows

- Each chat session keeps at most 50 messages in RAM.
- All messages stay in the SQLite store, `openclaw.db` in the app's Documents directory.
- When the app goes to the background, it trims the message windows and optimises the store.
- A trim empties the windows of the inactive sessions and cuts the active session to 50 messages.

## SQLite store

`OCStore` (`Frameworks/Store/Store.h`) uses WAL mode and caches prepared statements.

## Context budget

The agent sends at most **Max Context Tokens** of conversation to the model. The default is 2048. When the conversation is longer, the agent drops the oldest messages. A chat channel conversation uses at most 4096 tokens.

## WebSocket buffers

The remote gateway WebSocket client reads in 4 KB buffers, not the usual 64 KB.

## Unused helpers

`MemoryPool.h` also has `OCLRUCache`, a cache with a byte budget, and `OCBufferPool`, a pool of reusable buffers. The app does not use them yet.
