---
sidebar_position: 2
---

# Advanced Usage

## Path System

Synchronizer uses dot-separated paths to navigate nested data structures:

```lua
local channel = Synchronizer:Create("player_1", {
    stats = {
        health = 100;
        mana = 50;
    };
    equipment = {
        weapon = "Sword";
    };
})

-- Access nested values
channel:Set("stats.health", 80)
channel:Increase("stats.mana", 10)

-- Listen to nested paths
channel:OnChanged("stats.health", function(newHP, oldHP)
    print("HP:", oldHP, "→", newHP)
end)
```

## Chaining Mutations

All mutation methods that return `Channel` support chaining:

```lua
channel
    :Set("coins", 500)
    :Set("level", 10)
    :Increase("coins", 100)
```

All three mutations happen in memory immediately but are batched into a **single network payload** at the end of the frame.

## ClearSignal — Dynamic Entity Cleanup

When you have data keyed by dynamic UIDs, use `ClearSignal` to clean up all related signals at once:

```lua
-- Server: player has multiple heroes
local channel = Synchronizer:Create(player.UserId, {
    heroes = {
        ["hero_abc"] = { level = 5, exp = 120 };
        ["hero_xyz"] = { level = 3, exp = 45 };
    };
})

-- Client: listen to a specific hero
channel:OnChanged("heroes.hero_abc.level", function(newLevel)
    print("Hero leveled up to", newLevel)
end)

channel:OnChanged("heroes.hero_abc.exp", function(newExp)
    print("Hero exp:", newExp)
end)

-- When hero_abc is removed, clean up ALL signals containing "hero_abc"
channel:ClearSignal("hero_abc")
```

This destroys **every signal** whose path contains the string `"hero_abc"`, across all event types (Changed, ArrayInsert, ArrayRemoved, DictionaryInsert, DictionaryRemoved).

## WaitAndCall — Non-Yielding Initialization

Unlike `Wait`, which yields the current thread, `WaitAndCall` uses a callback approach:

```lua
-- This does NOT yield the thread
Synchronizer:WaitAndCall(player.UserId, function(channel)
    channel:OnChanged("coins", function(newValue)
        updateCoinUI(newValue)
    end, true)
end)

-- Code continues executing immediately
print("This runs without waiting!")
```

## Dictionary Operations

```lua
-- Insert key-value pairs
channel:InsertOnDictionary("equipment", "weapon", "Sword")
channel:InsertOnDictionary("equipment", "armor", "Iron Plate")

-- Listen for changes
channel:OnDictionaryInserted("equipment", function(value, key)
    print("Equipped:", key, "=", value)
end)

channel:OnDictionaryRemoved("equipment", function(value, key)
    print("Unequipped:", key)
end)

-- Remove a key
local removed = channel:RemoveFromDictionary("equipment", "weapon")
print("Removed:", removed) -- "Sword"
```

## Array Operations

```lua
-- Insert items
channel:InsertOnArray("inventory", "Sword")
channel:InsertOnArray("inventory", "Shield")
channel:InsertOnArray("inventory", "Potion", 1) -- insert at position 1

-- Listen for changes
channel:OnArrayInserted("inventory", function(item, index)
    print("Added:", item, "at", index)
end)

channel:OnArrayRemoved("inventory", function(item, index)
    print("Removed:", item, "from", index)
end)

-- Remove by index
local removed = channel:RemoveFromArray("inventory", 2)
```

## Configuration

Settings are defined at the top of the Synchronizer module:

```lua
local Settings = {
    MAX_REQUESTS_PER_SECOND = 10;  -- Rate limit for client data requests
    DESTROY_CLEANUP_DELAY = 5;     -- Seconds before remote cleanup after destroy
}
```

## Security Features

Synchronizer includes built-in security measures:

- **Listener Validation**: Clients can only request data from channels they are registered listeners of.
- **Rate Limiting**: Clients that exceed `MAX_REQUESTS_PER_SECOND` are temporarily blocked with a warning.
- **Data Validation**: Incoming client event data is type-checked before processing.
- **Cache Isolation**: Each client maintains its own cache table, independent of the server's reference table.
