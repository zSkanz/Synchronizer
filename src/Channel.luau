--!strict
--[[

		Synchronizer v3.0 — Channel
		By: Skanz.
		
		Represents a single synchronized data channel.
		Handles state mutations, event dispatching, listener
		management, and client-side cache synchronization.

]]--

--[=[
	@class Channel

	Represents a single synchronized data channel.

	A Channel holds a reference table (server) or cache table (client) and provides
	methods to mutate data, subscribe to changes, and manage which players receive
	updates. All mutations are batched per frame and sent as a single network payload.

	Channels are created through [Synchronizer:Create] and should not be
	instantiated directly.

	### Path System

	All mutation and event methods use dot-separated paths to navigate nested data:

	```lua
	channel:Set("stats.health", 80)
	channel:Increase("stats.mana", 10)
	channel:OnChanged("stats.health", function(newHP, oldHP)
		print("HP:", oldHP, "→", newHP)
	end)
	```

	### Chaining

	Mutation methods return `self` for chaining:

	```lua
	channel
		:Set("coins", 500)
		:Set("level", 10)
		:Increase("coins", 100)
	```
]=]

-- ** Services **

local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")

-- ** Constants **

local IS_SERVER: boolean = RunService:IsServer()
local SaveConnections: boolean = false

-- ** Dependencies **

local Signal = require(script.Parent.Parent.Signal)

-- ** Types **

type SignalMap = {[string]: Signal.Signal<any, any, any>}

type SignalStore = {
	Changed: SignalMap;
	ArrayInsert: SignalMap;
	ArrayRemoved: SignalMap;
	DictionaryInsert: SignalMap;
	DictionaryRemoved: SignalMap;
	[string]: SignalMap;
}

type ActionType = "Changed" | "ArrayInsert" | "ArrayRemoved" | "DictionaryInsert" | "DictionaryRemoved"

type ActionEntry = {
	[number]: any; -- [1] path, [2] actionType, [3] value, [4] extra, [5]? extra
}

export type Channel = {

	-- Attributes
	Index: any;
	ReferenceTable: {[any]: any}?;
	CacheTable: {[any]: any};
	CommunicationRoute: RemoteEvent;
	Queue: {ActionEntry};
	Synchronizer: any;
	Connections: {Signal.Connection | RBXScriptConnection};
	SavedConnections: {Signal.Connection};
	Signals: SignalStore;
	Listeners: {Player};
	OnDestroyed: Signal.Signal<Channel>;

	-- Mutations
	Set: (self: Channel, path: string, value: any) -> Channel;
	Increase: (self: Channel, path: string, value: number) -> Channel;
	InsertOnArray: (self: Channel, path: string, value: any, targetIndex: number?) -> number?;
	RemoveFromArray: (self: Channel, path: string, index: number) -> any?;
	InsertOnDictionary: (self: Channel, path: string, index: any, value: any) -> nil;
	RemoveFromDictionary: (self: Channel, path: string, index: any) -> any?;

	-- Events
	OnChanged: (self: Channel, path: string, callback: (newValue: any, oldValue: any) -> (), forceCall: boolean?) -> Signal.Connection;
	OnArrayInserted: (self: Channel, path: string, callback: (value: any, index: number) -> ()) -> Signal.Connection;
	OnArrayRemoved: (self: Channel, path: string, callback: (value: any, index: number) -> ()) -> Signal.Connection;
	OnDictionaryInserted: (self: Channel, path: string, callback: (value: any, index: any) -> ()) -> Signal.Connection;
	OnDictionaryRemoved: (self: Channel, path: string, callback: (value: any, index: any) -> ()) -> Signal.Connection;

	-- Listeners
	AddListener: (self: Channel, listener: Player) -> Channel;
	RemoveListener: (self: Channel, listener: Player) -> Channel;
	GetListeners: (self: Channel) -> {Player};

	-- Getters
	Get: (self: Channel, path: string?) -> any;
	GetTable: (self: Channel) -> {[any]: any};
	GetIndex: (self: Channel) -> any;

	-- Cleanup
	ClearSignal: (self: Channel, signalIdentifier: string) -> Channel;
	Destroy: (self: Channel, synchronizerCall: boolean?) -> nil;

}

--[=[
	@prop OnDestroyed Signal<Channel>
	@within Channel
	@tag Events
	Fires when this channel is destroyed.
]=]

-- ** Channel Class **

local Channel = {}
Channel.__index = Channel

-- ** Private Helpers **

local function ResolvePath(path: string, source: {[any]: any}): (any, {[any]: any}?, any)
	local segments = string.split(path, ".")
	local current: any = source
	local parent: {[any]: any}? = nil
	local lastKey: any = nil

	for i = 1, #segments do
		local key: any = tonumber(segments[i]) or segments[i]
		parent = current
		current = current[key]
		lastKey = key

		if current == nil and i < #segments then
			return nil, nil, nil
		end
	end

	return current, parent, lastKey
end

local function GetOrCreateSignal(store: SignalMap, path: string): Signal.Signal<any, any, any>
	local signal = store[path]
	if not signal then
		signal = Signal.new()
		store[path] = signal
	end
	return signal
end

local function FireAction(self: Channel, actionEntry: ActionEntry)
	local path: string = actionEntry[1]
	local actionType: string = actionEntry[2]

	if path == "" then return end

	local signalMap = self.Signals[actionType :: ActionType]
	if not signalMap then return end

	local targetSignal = signalMap[path]
	if targetSignal then
		targetSignal:Fire(actionEntry[3], actionEntry[4], actionEntry[5])
	end
end

local function InsertOnQueue(self: Channel, actionEntry: ActionEntry)
	local path: string = actionEntry[1]
	local action: string = actionEntry[2]

	-- For simple value changes, deduplicate: keep only the latest per path
	if action == "Changed" then
		for i = #self.Queue, 1, -1 do
			local queued = self.Queue[i]
			if queued[1] == path and queued[2] == "Changed" then
				table.remove(self.Queue, i)
				break
			end
		end
	end

	table.insert(self.Queue, actionEntry)
end

local function DispatchQueuedActions(self: Channel)
	if #self.Queue == 0 then return end

	-- Swap the queue: take ownership of current actions, give channel a fresh queue
	local actions = self.Queue
	self.Queue = {}

	-- Fire local signals
	for i = 1, #actions do
		FireAction(self, actions[i])
	end

	-- Replicate to listeners (each client gets its own copy of the reference)
	if IS_SERVER then
		for _, player: Player in self.Listeners do
			self.CommunicationRoute:FireClient(player, actions)
		end
	end
end

local function ApplyClientAction(self: Channel, data: {any})
	local path: string = data[1]
	local actionType: string = data[2]
	local dataTable = self:GetTable()

	local value, parentTable, key = ResolvePath(path, dataTable)

	if actionType == "Changed" then
		local newValue = data[3]
		data[4] = value
		if parentTable and key then
			parentTable[key] = newValue
		end

	elseif actionType == "ArrayInsert" then
		if value and typeof(value) == "table" then
			table.insert(value, data[4], data[3])
		end

	elseif actionType == "ArrayRemoved" then
		if value and typeof(value) == "table" then
			table.remove(value, data[4])
		end

	elseif actionType == "DictionaryInsert" then
		if value and typeof(value) == "table" then
			value[data[4]] = data[3]
		end

	elseif actionType == "DictionaryRemoved" then
		if value and typeof(value) == "table" then
			value[data[4]] = nil
		end
	end

	FireAction(self, data)
end

-- ** Constructor **

--[=[
	@function new
	@within Channel
	@private

	Creates a new Channel instance. This is called internally by [Synchronizer:Create]
	and should not be used directly.

	@param index any
	@param referenceTable {[any]: any}?
	@param synchronizer any
	@param isServer boolean
	@param settings {[string]: any}
	@return Channel
]=]
function Channel.new(index: any, referenceTable: {[any]: any}?, synchronizer: any, isServer: boolean, settings: {[string]: any}): Channel
	local self = setmetatable({}, Channel) :: Channel

	self.Index = index
	self.Queue = {}
	self.Synchronizer = synchronizer
	self.Connections = {}
	self.SavedConnections = {}
	self.OnDestroyed = Signal.new()

	-- Listeners
	self.Listeners = {}

	-- Signals
	self.Signals = {
		Changed = {};
		ArrayInsert = {};
		ArrayRemoved = {};
		DictionaryInsert = {};
		DictionaryRemoved = {};
	}

	-- Reference Table (server) / Cache Table (client)
	if IS_SERVER then
		self.ReferenceTable = referenceTable or {}
	end

	-- Communication Route
	if IS_SERVER then
		local route = Instance.new("RemoteEvent")
		route.Name = tostring(index)
		route.Parent = script
		self.CommunicationRoute = route
	else
		self.CommunicationRoute = script:WaitForChild(tostring(index)) :: RemoteEvent
	end

	-- Client: fetch initial data and listen for updates
	if not IS_SERVER then

		local RequestData: RemoteFunction = script.Parent:WaitForChild("RequestData") :: RemoteFunction
		local success, result = pcall(function()
			return RequestData:InvokeServer(self:GetIndex())
		end)

		self.CacheTable = if success and result then result else {}

		local clientConnection = self.CommunicationRoute.OnClientEvent:Connect(function(actionList)
			if typeof(actionList) ~= "table" then return end

			for i = 1, #actionList do
				ApplyClientAction(self, actionList[i])
			end
		end)

		table.insert(self.Connections, clientConnection)
	end

	-- Server: dispatch queued actions every frame
	if IS_SERVER then
		local steppedConnection = RunService.Stepped:Connect(function()
			DispatchQueuedActions(self)
		end)

		table.insert(self.Connections, steppedConnection)
	end

	return self
end

-- ** Mutation Methods **

--[=[
	Sets a value at the given path. Returns `self` for chaining.

	```lua
	channel:Set("coins", 100)
	channel:Set("stats.health", 80)
	```

	@param path string -- Dot-separated path to the value
	@param value any -- New value to set
	@return Channel
	@tag Mutations
]=]
function Channel.Set(self: Channel, path: string, value: any): Channel
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")

	local currentValue, targetTable, key = ResolvePath(path, self:GetTable())
	if not targetTable or key == nil then
		warn(`[Channel] Set failed: path '{path}' could not be resolved.`)
		return self
	end

	targetTable[key] = value
	InsertOnQueue(self, {path, "Changed", value, currentValue})

	return self
end

--[=[
	Increments a numeric value at the given path. Returns `self` for chaining.

	```lua
	channel:Increase("coins", 50)
	channel:Increase("stats.exp", 200)
	```

	@param path string -- Dot-separated path to a numeric value
	@param value number -- Amount to add
	@return Channel
	@tag Mutations
]=]
function Channel.Increase(self: Channel, path: string, value: number): Channel
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	assert(value and typeof(value) == "number", "[Channel] Increase value must be a number.")

	local currentValue, targetTable, key = ResolvePath(path, self:GetTable())
	if not targetTable or key == nil then
		warn(`[Channel] Increase failed: path '{path}' could not be resolved.`)
		return self
	end

	if typeof(currentValue) ~= "number" then
		warn(`[Channel] Increase failed: value at '{path}' is not a number.`)
		return self
	end

	local newValue = currentValue + value
	targetTable[key] = newValue
	InsertOnQueue(self, {path, "Changed", newValue, currentValue})

	return self
end

--[=[
	Inserts a value into an array at the given path. Returns the insertion index.

	```lua
	channel:InsertOnArray("inventory", "Sword")
	channel:InsertOnArray("inventory", "Shield", 1) -- insert at position 1
	```

	@param path string -- Dot-separated path to the array
	@param value any -- Value to insert
	@param targetIndex number? -- Optional position (appends if nil)
	@return number? -- The index where the value was inserted
	@tag Mutations
]=]
function Channel.InsertOnArray(self: Channel, path: string, value: any, targetIndex: number?): number?
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	assert(value ~= nil, "[Channel] Value cannot be nil.")

	if targetIndex ~= nil then
		assert(typeof(targetIndex) == "number", "[Channel] Target index must be a number.")
	end

	local targetTable = ResolvePath(path, self:GetTable())
	if not targetTable or typeof(targetTable) ~= "table" then
		warn(`[Channel] InsertOnArray failed: path '{path}' is not a table.`)
		return nil
	end

	local insertIndex: number
	if targetIndex then
		table.insert(targetTable, targetIndex, value)
		insertIndex = targetIndex
	else
		table.insert(targetTable, value)
		insertIndex = #targetTable
	end

	InsertOnQueue(self, {path, "ArrayInsert", value, insertIndex})
	return insertIndex
end

--[=[
	Removes a value from an array at the given index. Returns the removed value.

	```lua
	local removed = channel:RemoveFromArray("inventory", 1)
	```

	@param path string -- Dot-separated path to the array
	@param targetIndex number -- Index to remove
	@return any? -- The removed value
	@tag Mutations
]=]
function Channel.RemoveFromArray(self: Channel, path: string, targetIndex: number): any?
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	assert(targetIndex and typeof(targetIndex) == "number", "[Channel] Target index must be a number.")

	local targetTable = ResolvePath(path, self:GetTable())
	if not targetTable or typeof(targetTable) ~= "table" then
		warn(`[Channel] RemoveFromArray failed: path '{path}' is not a table.`)
		return nil
	end

	local removed = table.remove(targetTable, targetIndex)
	InsertOnQueue(self, {path, "ArrayRemoved", removed, targetIndex})

	return removed
end

--[=[
	Inserts a key-value pair into a dictionary at the given path.

	```lua
	channel:InsertOnDictionary("equipment", "weapon", "Sword")
	```

	@param path string -- Dot-separated path to the dictionary
	@param index any -- Key to insert
	@param value any -- Value to insert
	@tag Mutations
]=]
function Channel.InsertOnDictionary(self: Channel, path: string, index: any, value: any): nil
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	assert(index ~= nil, "[Channel] Dictionary index cannot be nil.")
	assert(value ~= nil, "[Channel] Value cannot be nil.")

	local targetTable = ResolvePath(path, self:GetTable())
	if not targetTable or typeof(targetTable) ~= "table" then
		warn(`[Channel] InsertOnDictionary failed: path '{path}' is not a table.`)
		return nil
	end

	targetTable[index] = value
	InsertOnQueue(self, {path, "DictionaryInsert", value, index})

	return nil
end

--[=[
	Removes a key from a dictionary at the given path. Returns the removed value.

	```lua
	local removed = channel:RemoveFromDictionary("equipment", "weapon")
	```

	@param path string -- Dot-separated path to the dictionary
	@param index any -- Key to remove
	@return any? -- The removed value
	@tag Mutations
]=]
function Channel.RemoveFromDictionary(self: Channel, path: string, index: any): any?
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	assert(index ~= nil, "[Channel] Dictionary index cannot be nil.")

	local targetTable = ResolvePath(path, self:GetTable())
	if not targetTable or typeof(targetTable) ~= "table" then
		warn(`[Channel] RemoveFromDictionary failed: path '{path}' is not a table.`)
		return nil
	end

	local value = targetTable[index]
	targetTable[index] = nil
	InsertOnQueue(self, {path, "DictionaryRemoved", value, index})

	return value
end

-- ** Event Methods **

--[=[
	Subscribes to value changes at the given path.

	```lua
	channel:OnChanged("coins", function(newValue, oldValue)
		print("Coins:", oldValue, "→", newValue)
	end, true) -- true = fire immediately with current value
	```

	@param path string -- Dot-separated path to observe
	@param callback (newValue: any, oldValue: any) -> () -- Handler function
	@param forceCall boolean? -- If true, fires callback immediately with current value
	@return Connection
	@tag Events
]=]
function Channel.OnChanged(self: Channel, path: string, callback: (newValue: any, oldValue: any) -> (), forceCall: boolean?): Signal.Connection
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")

	local signal = GetOrCreateSignal(self.Signals.Changed, path)

	if forceCall == true then
		task.spawn(callback, self:Get(path), nil)
	end

	local connection = signal:Connect(callback)
	if SaveConnections then
		table.insert(self.SavedConnections, connection)
	end
	return connection
end

--[=[
	Subscribes to array insertion events at the given path.

	```lua
	channel:OnArrayInserted("inventory", function(value, index)
		print("New item:", value, "at index", index)
	end)
	```

	@param path string -- Dot-separated path to the array
	@param callback (value: any, index: number) -> () -- Handler function
	@return Connection
	@tag Events
]=]
function Channel.OnArrayInserted(self: Channel, path: string, callback: (value: any, index: number) -> ()): Signal.Connection
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	local connection = GetOrCreateSignal(self.Signals.ArrayInsert, path):Connect(callback)
	if SaveConnections then
		table.insert(self.SavedConnections, connection)
	end
	return connection
end

--[=[
	Subscribes to array removal events at the given path.

	```lua
	channel:OnArrayRemoved("inventory", function(value, index)
		print("Removed:", value, "from index", index)
	end)
	```

	@param path string -- Dot-separated path to the array
	@param callback (value: any, index: number) -> () -- Handler function
	@return Connection
	@tag Events
]=]
function Channel.OnArrayRemoved(self: Channel, path: string, callback: (value: any, index: number) -> ()): Signal.Connection
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	local connection = GetOrCreateSignal(self.Signals.ArrayRemoved, path):Connect(callback)
	if SaveConnections then
		table.insert(self.SavedConnections, connection)
	end
	return connection
end

--[=[
	Subscribes to dictionary insertion events at the given path.

	```lua
	channel:OnDictionaryInserted("equipment", function(value, key)
		print("Equipped:", key, "=", value)
	end)
	```

	@param path string -- Dot-separated path to the dictionary
	@param callback (value: any, index: any) -> () -- Handler function
	@return Connection
	@tag Events
]=]
function Channel.OnDictionaryInserted(self: Channel, path: string, callback: (value: any, index: any) -> ()): Signal.Connection
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	local connection = GetOrCreateSignal(self.Signals.DictionaryInsert, path):Connect(callback)
	if SaveConnections then
		table.insert(self.SavedConnections, connection)
	end
	return connection
end

--[=[
	Subscribes to dictionary removal events at the given path.

	```lua
	channel:OnDictionaryRemoved("equipment", function(value, key)
		print("Unequipped:", key)
	end)
	```

	@param path string -- Dot-separated path to the dictionary
	@param callback (value: any, index: any) -> () -- Handler function
	@return Connection
	@tag Events
]=]
function Channel.OnDictionaryRemoved(self: Channel, path: string, callback: (value: any, index: any) -> ()): Signal.Connection
	assert(path and typeof(path) == "string", "[Channel] Path must be a non-empty string.")
	local connection = GetOrCreateSignal(self.Signals.DictionaryRemoved, path):Connect(callback)
	if SaveConnections then
		table.insert(self.SavedConnections, connection)
	end
	return connection
end

-- ** Listener Methods **

--[=[
	Adds a player as a listener. The player will receive all future updates
	from this channel. Returns `self` for chaining.

	:::info Server Only
	This method should only be called from the server.
	:::

	```lua
	channel:AddListener(player)
	```

	@param listener Player -- Player to add
	@return Channel
	@tag Listeners
]=]
function Channel.AddListener(self: Channel, listener: Player): Channel
	if table.find(self.Listeners, listener) then
		return self
	end

	table.insert(self.Listeners, listener)
	self.Synchronizer.OnChannelListenerAdded:Fire(self, listener)

	return self
end

--[=[
	Removes a player from the listener list. The player will no longer
	receive updates from this channel. Returns `self` for chaining.

	:::info Server Only
	This method should only be called from the server.
	:::

	```lua
	channel:RemoveListener(player)
	```

	@param listener Player -- Player to remove
	@return Channel
	@tag Listeners
]=]
function Channel.RemoveListener(self: Channel, listener: Player): Channel
	local index = table.find(self.Listeners, listener)
	if not index then
		return self
	end

	table.remove(self.Listeners, index)
	self.Synchronizer.OnChannelListenerRemoved:Fire(self, listener)

	return self
end

--[=[
	Returns the list of players currently listening to this channel.

	```lua
	local listeners = channel:GetListeners()
	```

	@return {Player}
	@tag Listeners
]=]
function Channel.GetListeners(self: Channel): {Player}
	return self.Listeners
end

-- ** Getter Methods **

--[=[
	Returns the value at the given path, or the full data table if no path is provided.

	```lua
	local coins = channel:Get("coins")
	local stats = channel:Get("stats")
	local allData = channel:Get() -- returns full table
	```

	@param path string? -- Optional dot-separated path
	@return any
	@tag Getters
]=]
function Channel.Get(self: Channel, path: string?): any
	if not path then
		return self:GetTable()
	end
	return (ResolvePath(path, self:GetTable()))
end

--[=[
	Returns the channel's unique index.

	```lua
	local index = channel:GetIndex()
	```

	@return any
	@tag Getters
]=]
function Channel.GetIndex(self: Channel): any
	return self.Index
end

--[=[
	Returns the raw data table. On the server, this is the reference table.
	On the client, this is the cached copy.

	```lua
	local data = channel:GetTable()
	```

	@return {[any]: any}
	@tag Getters
]=]
function Channel.GetTable(self: Channel): {[any]: any}
	return (if IS_SERVER then self.ReferenceTable else self.CacheTable) :: {[any]: any}
end

-- ** Cleanup Methods **

--[=[
	Destroys all signals whose path contains the given identifier.
	Useful for cleaning up signals related to a dynamic entity (e.g. a UID).

	```lua
	-- If you have signals on "heroes.hero_abc.level", "heroes.hero_abc.exp", etc.
	channel:ClearSignal("hero_abc")
	-- All signals containing "hero_abc" are destroyed
	```

	@param signalIdentifier string -- Substring to match against signal paths
	@return Channel
	@tag Cleanup
]=]
function Channel.ClearSignal(self: Channel, signalIdentifier: string): Channel
	for _, signalMap: SignalMap in self.Signals :: any do
		for path, signal in signalMap do
			if string.find(path, signalIdentifier, 1, true) then
				signal:DisconnectAll()
				signal:Destroy()
				signalMap[path] = nil
			end
		end
	end

	return self
end

--[=[
	Destroys this channel and all associated resources including signals,
	connections, listeners, and remote events.

	When called directly, it delegates to [Synchronizer:Destroy] for proper cleanup.

	```lua
	channel:Destroy()
	```

	@tag Cleanup
]=]
function Channel.Destroy(self: Channel, synchronizerCall: boolean?): nil
	-- If not called from Synchronizer, delegate to it for proper cleanup
	if synchronizerCall ~= true then
		return self.Synchronizer:Destroy(self:GetIndex())
	end

	-- Remove all listeners first (notifies clients)
	if IS_SERVER then
		for i = #self.Listeners, 1, -1 do
			self:RemoveListener(self.Listeners[i])
		end

		-- Rename and schedule remote destruction to avoid race conditions
		self.CommunicationRoute.Name = HttpService:GenerateGUID(false)
		Debris:AddItem(self.CommunicationRoute, 5)
	end

	-- Fire destroyed signal
	self.OnDestroyed:Fire(self)
	self.OnDestroyed:DisconnectAll()
	self.OnDestroyed:Destroy()

	-- Disconnect all connections
	for _, connection in self.Connections do
		if typeof(connection) == "RBXScriptConnection" then
			(connection :: RBXScriptConnection):Disconnect()
		else
			(connection :: Signal.Connection):Disconnect()
		end
	end

	-- Destroy all signals
	for _, signalMap: SignalMap in self.Signals :: any do
		for path, signal in signalMap do
			signal:DisconnectAll()
			signal:Destroy()
		end
	end

	-- Disconnect saved connections
	for _, connection in self.SavedConnections do
		connection:Disconnect()
	end

	-- Clear internal state
	table.clear(self.SavedConnections)
	table.clear(self.Queue)
	table.clear(self.Connections)
	table.clear(self.Listeners)
	setmetatable(self :: any, nil)

	return nil
end

return Channel
