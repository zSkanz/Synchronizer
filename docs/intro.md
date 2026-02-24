---
sidebar_position: 1
---

# Getting Started

Synchronizer is a high-performance state synchronization library for Roblox. It manages server-authoritative data channels with automatic client replication, batched networking, and event-driven updates.

## Installation

### Manual (Roblox Studio)

1. Create a **ModuleScript** named `Synchronizer` inside `ReplicatedStorage/Packages`.
2. Create a child **ModuleScript** named `Channel` inside it.
3. Copy the contents of [`src/Synchronizer.luau`](https://github.com/zSkanz/Synchronizer/blob/main/src/Synchronizer.luau) and [`src/Channel.luau`](https://github.com/zSkanz/Synchronizer/blob/main/src/Channel.luau) respectively.

Your hierarchy should look like this:

```
ReplicatedStorage
└── Packages
    ├── Synchronizer         ← Synchronizer.luau
    │   └── Channel          ← Channel.luau
    └── Signal               ← (dependency)
```

### Rojo / Filesystem

Clone the repository and sync the `src/` folder into your project:

```bash
git clone https://github.com/zSkanz/Synchronizer.git
```

### Dependencies

Synchronizer requires a **Signal** module as a sibling inside `Packages`. We recommend [sleitnick/signal](https://github.com/sleitnick/signal).

## Basic Usage

### Server

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Synchronizer = require(ReplicatedStorage.Packages.Synchronizer)

Players.PlayerAdded:Connect(function(player)
    -- Create a channel with initial data
    local channel = Synchronizer:Create(player.UserId, {
        coins = 0;
        level = 1;
        inventory = {};
    })

    -- Register the player as a listener
    channel:AddListener(player)

    -- Mutate data — clients update automatically
    channel:Set("coins", 100)
    channel:Increase("coins", 50)
    channel:InsertOnArray("inventory", "Sword")
end)

Players.PlayerRemoving:Connect(function(player)
    Synchronizer:Destroy(player.UserId)
end)
```

### Client

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Synchronizer = require(ReplicatedStorage.Packages.Synchronizer)

local channel = Synchronizer:Wait(game.Players.LocalPlayer.UserId)

-- Listen for changes (forceCall = true fires immediately with current value)
channel:OnChanged("coins", function(newValue, oldValue)
    print("Coins:", oldValue, "→", newValue)
end, true)

channel:OnArrayInserted("inventory", function(item, index)
    print("New item:", item, "at index", index)
end)

-- Read values directly
local coins = channel:Get("coins")
local allData = channel:GetTable()
```

## How It Works

```
Server                                          Client
┌─────────────────────┐                  ┌─────────────────────┐
│  Synchronizer       │                  │  Synchronizer       │
│  ├── Channel A      │   FireClient     │  ├── Channel A      │
│  │   ├── Set()  ────┼──(batched/frame)─┼──│   ├── CacheTable │
│  │   ├── Queue  ────┼─────────────────►│  │   ├── OnChanged  │
│  │   └── Listeners  │                  │  │   └── Signals    │
│  └── Channel B      │                  │  └── Channel B      │
└─────────────────────┘                  └─────────────────────┘
```

1. **Server** mutates data via `Set`, `Increase`, `InsertOnArray`, etc.
2. Mutations are queued and **deduplicated** within the frame.
3. On `RunService.Stepped`, all queued actions are **batched** and sent to listeners.
4. **Client** receives the batch, updates its cache, and fires local signals.
