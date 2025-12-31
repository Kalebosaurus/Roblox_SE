-- NetworkService Module
-- Provides a networking API for client-server communication with built-in middleware support.

-- Currently supports:
-- - Remote Events and Functions
-- - Rate Limiting middleware
-- - Async/safe request handling with timeouts
-- - Debug/logging toggle

-- TODO: Add player state buffering, validation middleware (lower priority), and more as needed.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Network = {}
Network._connections = {}
Network._rateLimits = {} 

-- Configuration
local REMOTES_FOLDER_NAME = "GameRemotes"
local IS_SERVER = RunService:IsServer()

-- Debug / Logging Toggle
Network.ShowDebugLogs = false 

-- Setup Folder
local RemotesFolder
if IS_SERVER then
	RemotesFolder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if not RemotesFolder then
		RemotesFolder = Instance.new("Folder")
		RemotesFolder.Name = REMOTES_FOLDER_NAME
		RemotesFolder.Parent = ReplicatedStorage
	end
else
	RemotesFolder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
end

-- Helper: Get/Create Remote
local function getRemote(name, remoteType)
	local remote = RemotesFolder:FindFirstChild(name)
	if not remote then
		if IS_SERVER then
			remote = Instance.new(remoteType)
			remote.Name = name
			remote.Parent = RemotesFolder
		else
			remote = RemotesFolder:WaitForChild(name, 10)
			if not remote then
				warn("[Network] Client timed out waiting for remote: " .. name)
				return nil
			end
		end
	end
	return remote
end

-- Helper: Rate Limit Check
local function checkRateLimit(player, remoteName, minInterval)
	if not player then return true end -- Local events might not have a player
	
	local key = player.UserId .. "_" .. remoteName
	local lastTime = Network._rateLimits[key] or 0
	local now = os.clock()
	
	if now - lastTime < minInterval then
		return false -- Rate limit exceeded
	end
	
	Network._rateLimits[key] = now
	return true
end

-- Helper: Log Traffic
local function logTraffic(direction, name, player, ...)
	if not Network.ShowDebugLogs then return end
	local args = {...}
	local argCount = #args
	local playerInfo = player and ("[" .. player.Name .. "]") or "[System]"
	print(string.format("[Network %s] %s %s invoked '%s' with %d args", direction, playerInfo, (IS_SERVER and "Server" or "Client"), name, argCount))
end

--------------------------------------------------------------------------------
-- API: Fire (Sending Data)
--------------------------------------------------------------------------------

-- 'name' is the remote event name, this is required.
function Network.FireServer(name: string, ...)
	if IS_SERVER then return warn("[Network] Cannot fire server from server") end
	logTraffic("OUT", name, game.Players.LocalPlayer, ...)
	local remote = getRemote(name, "RemoteEvent")
	if remote then remote:FireServer(...) end
end

-- Fire to a specific client specified by 'player'. 'name' is the remote event name, this is required.
function Network.FireClient(player: Player, name: string, ...)
	if not IS_SERVER then return warn("[Network] Cannot fire client from client") end
	logTraffic("OUT", name, player, ...)
	local remote = getRemote(name, "RemoteEvent")
	if remote then remote:FireClient(player, ...) end
end

-- Fire to ALL connected clients. 'name' is the remote event name, this is required.
function Network.FireAllClients(name: string, ...)
	if not IS_SERVER then return warn("[Network] Cannot fire all clients from client") end
	logTraffic("OUT", name, nil, "ALL_CLIENTS", ...)
	local remote = getRemote(name, "RemoteEvent")
	if remote then remote:FireAllClients(...) end
end

--------------------------------------------------------------------------------
-- API: Listen (Receiving Data with Middleware)
--------------------------------------------------------------------------------

type ListenOptions = {
	RateLimit: number?,  -- Minimum seconds between calls
	-- Validators could go here (e.g., Types = { "string", "number" }), not necessary for now but useful for eventual release.
}

-- Listen for events from Server (Server -> Client) or Client (Client -> Server)
-- 'name' is the remote event name, 'callback' is the function to call when event is received.
-- 'options' is an optional table for middleware settings like rate limiting.
function Network.Listen(name: string, callback, options: ListenOptions?)
	local remote = getRemote(name, "RemoteEvent")
	if not remote then return end

	local connection
	if IS_SERVER then
		connection = remote.OnServerEvent:Connect(function(player, ...)
			logTraffic("IN", name, player, ...)
			
			-- Rate Limiting
			if options and options.RateLimit then
				if not checkRateLimit(player, name, options.RateLimit) then
					if Network.ShowDebugLogs then warn("[Network] Rate limit hit: " .. name) end
					return
				end
			end
			
			callback(player, ...)
		end)
	else
		-- Client Listener
		connection = remote.OnClientEvent:Connect(function(...)
			logTraffic("IN", name, game.Players.LocalPlayer, ...)
			callback(...) 
		end)
	end

	table.insert(Network._connections, connection)
	return connection
end

--------------------------------------------------------------------------------
-- API: Async Requests (Promises / Safe Invokes)
--------------------------------------------------------------------------------

-- Request data from Server (Client -> Server -> Client)
-- Safe wrapper that handles timeouts so the client doesn't freeze
function Network.InvokeServerAsync(name: string, timeout: number, ...)
	if IS_SERVER then return end
	local remote = getRemote(name, "RemoteFunction")
	if not remote then return nil end
	
	logTraffic("INVOKE_OUT", name, game.Players.LocalPlayer, ...)

	local result
	local finished = false
	
	-- Run the invoke in a separate thread so we can timeout
	task.spawn(function(...)
		result = {remote:InvokeServer(...)}
		finished = true
	end, ...)
	
	-- Wait loop
	local start = os.clock()
	while not finished do
		if (os.clock() - start) > (timeout or 5) then
			warn("[Network] InvokeServerAsync timed out: " .. name)
			return nil -- or throw error depending on preference
		end
		task.wait()
	end
	
	return table.unpack(result)
end

-- Handle Request on Server
function Network.HandleInvoke(name: string, callback)
	if not IS_SERVER then return end
	local remote = getRemote(name, "RemoteFunction")
	
	remote.OnServerInvoke = function(player, ...)
		logTraffic("INVOKE_IN", name, player, ...)
		return callback(player, ...)
	end
end

return Network