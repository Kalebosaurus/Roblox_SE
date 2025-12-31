-- PlayerStateService.luau
-- Manages player states (unconscious, riding, inventory open, sprinting) and stats (health, food, water, torpor, weight).
-- TODO: Handles loading/saving of persistent stats and replicating transient states via Attributes.
-- TODO: Optimize by batching updates in modifyStats/Heartbeat functions later if required.
-- TODO: Possibly add tracking for equipped items. Not sure whether that belongs here for now.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- If you have ProfileService later, you'd require it here.
-- For now, we use a simple table for data storage.
local PlayerStateService = {}
PlayerStateService.Name = "PlayerStateService"
PlayerStateService.ClientData = {} -- Stores loaded data (Health, Food, etc.)

-- Default Stats for a fresh spawn
local DEFAULT_STATS = {
	Health = 100,
	MaxHealth = 100,
	Stamina = 100,
    MaxStamina = 100,
	Food = 100,
	Water = 100,
	Torpor = 0,
	Weight = 0,
}

-- Dependencies
local Framework = nil 
local Network = nil

function PlayerStateService:Init(Loader)
	Framework = Loader
	Network = require(ReplicatedStorage.Shared.Network)
	
	print("[PlayerStateService] Initialized")
end

function PlayerStateService:Start()
	-- Connect Player Lifecycle
	Players.PlayerAdded:Connect(function(player) self:OnPlayerJoin(player) end)
	Players.PlayerRemoving:Connect(function(player) self:OnPlayerLeave(player) end)
	
	-- Handle existing players (on server script reload for example, likely not used in normal play)
	for _, player in ipairs(Players:GetPlayers()) do
		self:OnPlayerJoin(player)
	end
end

--------------------------------------------------------------------------------
-- Data & Lifecycle
--------------------------------------------------------------------------------

function PlayerStateService:OnPlayerJoin(player)
	-- 1. Initialize Transient States (Attributes)
	-- These are "Flags" used by InputHandler
	player:SetAttribute("IsUnconscious", false) -- Persitant state, save in ProfileService later
	player:SetAttribute("IsRiding", false)
	player:SetAttribute("IsInventoryOpen", false)
	player:SetAttribute("IsSprinting", false)
	
	-- 2. Load Persistent Stats
	-- (In the future, load from ProfileService (or similar) here)
	local data = table.clone(DEFAULT_STATS)
	self.ClientData[player.UserId] = data
	
	-- 3. Send initial data to client
	task.wait(1) -- Brief wait to ensure client loaded. TODO: improve later with proper handshake/signaling
	Network.FireClient(player, "SyncStats", data)

    -- 4. Listen for client requests (e.g., data sync requests)
    -- Usually only used in edge cases where client loads late
    Network.Listen("RequestSync", function()
        Network.FireClient(player, "SyncStats", data)
    end)
end

function PlayerStateService:OnPlayerLeave(player)
	self.ClientData[player.UserId] = nil
	-- (Save data to ProfileService here)
end

--------------------------------------------------------------------------------
-- State Management API
--------------------------------------------------------------------------------

-- Set a boolean state (Replicates via Attributes)
function PlayerStateService:SetState(player: Player, stateName: string, value: boolean)
	-- Security check: Ensure we aren't setting random attributes
	if player:GetAttribute(stateName) ~= nil then
		player:SetAttribute(stateName, value)
	else
		warn("Attempted to set invalid state: " .. stateName)
	end
end

-- Toggle a state
function PlayerStateService:ToggleState(player: Player, stateName: string)
	local current = player:GetAttribute(stateName)
	if current ~= nil then
		player:SetAttribute(stateName, not current)
	end
end

-- Check a state (Server side check)
function PlayerStateService:GetState(player: Player, stateName: string)
	return player:GetAttribute(stateName)
end

--------------------------------------------------------------------------------
-- Stat Management API (Health, Food, etc.)
--------------------------------------------------------------------------------

function PlayerStateService:GetStat(player: Player, statName: string)
	local data = self.ClientData[player.UserId]
	if data and data[statName] ~= nil then
		return data[statName]
	end
	return 0
end

-- Modify a stat by a certain amount (positive or negative) and sync to client
function PlayerStateService:ModifyStat(player: Player, statName: string, amount: number)
	local data = self.ClientData[player.UserId]
	if not data or not data[statName] then return end
	
	-- Apply change
	data[statName] = math.clamp(data[statName] + amount, 0, data["Max" .. statName] or 999999)
	
	-- Handle consequences (Example: High Torpor = Unconscious)
	if statName == "Torpor" then
		if data.Torpor >= 50 then -- Threshold
			self:SetState(player, "IsUnconscious", true)
		else
			self:SetState(player, "IsUnconscious", false)
		end
	end
	
	-- Replicate to client
	Network.FireClient(player, "StatChanged", statName, data[statName])
end

-- Modifies stats over time (called every frame via the ServiceLoader centralized heartbeat)
function PlayerStateService:Heartbeat(dt)
	-- We use a timer to not run logic every single frame
	
    -- Example: Simple ticker
	if (os.clock() % 1 < dt) then -- Run roughly once per second
		for userId, data in pairs(self.ClientData) do
            -- Find the player object
            local player = Players:GetPlayerByUserId(userId)
            if player then
                -- Reduce Food/Water
                -- We use the ModifyStat method to ensure replication happens
                -- self:ModifyStat(player, "Food", -0.1)
                -- self:ModifyStat(player, "Water", -0.2)
            end
		end
	end
end

return PlayerStateService