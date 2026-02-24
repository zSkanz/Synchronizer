# Changelog

All notable changes to Synchronizer will be documented in this file.

## [3.0.0] — 2026

### Added
- **Security:** Listener validation on `RequestData` — only listeners can request channel data.
- **Security:** Rate limiting on client requests (configurable `MAX_REQUESTS_PER_SECOND`).
- **Security:** Type validation on incoming client event data.
- **Cleanup:** `Players.PlayerRemoving` handler to clear rate limit cache (prevents memory accumulation).
- **API:** `Channel:GetListeners()` method.
- **Config:** `Settings` table at module top for easy configuration.
- **Errors:** Descriptive `[Synchronizer]` and `[Channel]` prefixed warnings on all error paths.

### Changed
- **Networking:** Queue swap pattern replaces `table.clear` — eliminates race conditions on dispatch.
- **WaitAndCall:** `WaitingList` initialized upfront in module definition (fixes nil bug on first call).
- **WaitAndCall:** `OnChannelCreated` listener connected once at initialization scope (not lazily).
- **OnChanged:** `forceCall` now uses `task.spawn` instead of direct invocation.
- **ClearSignal:** Simplified iteration — flat loop over signal maps instead of recursive traversal.
- **Destroy:** Added `table.clear` on all internal state tables after cleanup.
- **Typing:** Full `--!strict` with `SignalMap`, `SignalStore`, `ActionType`, `ActionEntry` types.
- **Typing:** `GetOrCreateSignal` helper eliminates code duplication across 5 event methods.
- **Typing:** `ApplyClientAction` extracted as dedicated function (was inline closure).
- **Typing:** `ResolvePath` returns `(nil, nil, nil)` tuple on invalid intermediate paths.
- **Constructor:** `ReferenceTable` defaults to `{}` when nil (prevents nil access errors).
- **Constructor:** Client-side `InvokeServer` wrapped in `pcall` for error resilience.

### Removed
- Dead `CommunicationRoute:FireServer()` call on client load (had no server handler).
- `SavedConnections` recursive loop in old `ClearSignal` (replaced with flat iteration).

## [2.7.0]

- Initial public version.
- Channel-based state synchronization.
- Batched networking via `RunService.Stepped`.
- Action deduplication for `Changed` events.
- Signal system: `Changed`, `ArrayInsert`, `ArrayRemoved`, `DictionaryInsert`, `DictionaryRemoved`.
- Listener system for per-player replication.
- `SaveConnections` flag for automatic connection tracking.
