-- NetworkService Module
-- Provides a minimal API for client-server communication using RemoteEvents and BindableEvents.

-- TODO: Expand with rate limiting, player state buffers, security checks, promises, possibly typechecking, etc.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = {}
Network._connections = {} -- Store connections to clean them up if needed

-- Configuration
local REMOTES_FOLDER_NAME = "GameRemotes"
local IS_SERVER = RunService:IsServer()

-- Setup the Folder
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

-- Helper: Get or Create Remote (Only server creates, Client waits)
local function getRemote(name, remoteType)
	local remote = RemotesFolder:FindFirstChild(name)
	
	if not remote then
		if IS_SERVER then
			remote = Instance.new(remoteType)
			remote.Name = name
			remote.Parent = RemotesFolder
		else
			-- Client waits for the server to create it
			remote = RemotesFolder:WaitForChild(name, 10)
			if not remote then
				warn("[Network] Client timed out waiting for remote: " .. name)
				return nil
			end
		end
	end
	
	if remote.ClassName ~= remoteType then
		error("[Network] Remote type mismatch for '" .. name .. "'. Expected " .. remoteType)
	end
	
	return remote
end

--------------------------------------------------------------------------------
-- API: Sending Data
--------------------------------------------------------------------------------

-- Fire to Server (Called from Client)
function Network.FireServer(name: string, ...)
	if IS_SERVER then return warn("[Network] Cannot fire server from server") end
	local remote = getRemote(name, "RemoteEvent")
	if remote then remote:FireServer(...) end
end

-- Fire to Client (Called from Server)
function Network.FireClient(player: Player, name: string, ...)
	if not IS_SERVER then return warn("[Network] Cannot fire client from client") end
	local remote = getRemote(name, "RemoteEvent")
	if remote then remote:FireClient(player, ...) end
end

-- Fire to ALL Clients (Called from Server)
function Network.FireAllClients(name: string, ...)
	if not IS_SERVER then return warn("[Network] Cannot fire all clients from client") end
	local remote = getRemote(name, "RemoteEvent")
	if remote then remote:FireAllClients(...) end
end

-- Fire Local (BindableEvent - Works on both Client and Server for local comms)
function Network.FireLocal(name: string, ...)
	local remote = getRemote("Local_" .. name, "BindableEvent")
	if remote then remote:Fire(...) end
end

--------------------------------------------------------------------------------
-- API: Listening for Data
--------------------------------------------------------------------------------

-- Connect to a network event
function Network.Listen(name: string, callback)
	local remote = getRemote(name, "RemoteEvent")
	if not remote then return end
	
	local connection
	if IS_SERVER then
		connection = remote.OnServerEvent:Connect(callback)
	else
		connection = remote.OnClientEvent:Connect(callback)
	end
	
	table.insert(Network._connections, connection)
	return connection
end

-- Connect to a local event
function Network.ListenLocal(name: string, callback)
	local remote = getRemote("Local_" .. name, "BindableEvent")
	local connection = remote.Event:Connect(callback)
	table.insert(Network._connections, connection)
	return connection
end

-- Clean up connections
function Network.Destroy()
	for _, conn in ipairs(Network._connections) do
		conn:Disconnect()
	end
	Network._connections = {}
end

return Network