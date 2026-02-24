<p align="center">
  <h1 align="center">⚡ Synchronizer</h1>
  <p align="center">
    A high-performance state synchronization library for Roblox.
  </p>
</p>

<p align="center">
  <a href="https://zskanz.github.io/Synchronizer"><img src="https://img.shields.io/badge/docs-website-blue?style=flat-square" /></a>
  <img src="https://img.shields.io/badge/version-3.0-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/luau-strict-purple?style=flat-square" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" />
</p>

---

## Overview

**Synchronizer** manages server-authoritative data channels with automatic client replication, batched networking, and event-driven updates. Instead of manually firing RemoteEvents, you mutate a channel and Synchronizer handles the rest.

📖 **[Read the full documentation →](https://zskanz.github.io/Synchronizer)**

## Features

- **Channel-Based Architecture** — Isolated, reusable data channels per-player, per-entity, or global.
- **Batched Networking** — All mutations within a frame sent as a single RemoteEvent per listener.
- **Action Deduplication** — Multiple `Set` calls to the same path only send the final value.
- **Event-Driven** — Subscribe to `Changed`, `ArrayInsert`, `ArrayRemoved`, `DictionaryInsert`, `DictionaryRemoved`.
- **Listener System** — Control which players receive updates from each channel.
- **Security** — Rate limiting and listener-only data access validation.
- **Strict Typing** — Full `--!strict` with exported types for IDE autocompletion.
- **Zero Memory Leaks** — Complete cleanup on channel destruction.

## Quick Example

```luau
-- Server
local channel = Synchronizer:Create(player.UserId, {
    coins = 0;
    level = 1;
})
channel:AddListener(player)
channel:Set("coins", 100):Increase("coins", 50)

-- Client
local channel = Synchronizer:Wait(player.UserId)
channel:OnChanged("coins", function(new, old)
    print("Coins:", old, "→", new)
end, true)
```

## Installation

See the [__Getting Started__](https://zskanz.github.io/Synchronizer/#getting-started) guide.

## License

[MIT](LICENSE) © 2026 Skanz
