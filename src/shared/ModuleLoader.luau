local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local ServiceLoader = {}
ServiceLoader.__index = ServiceLoader

export type Options = {
	root: Instance,          -- Folder to scan for ModuleScripts
	env: "Client"|"Server"|"Shared"?, -- optional environment filter
	autoStart: boolean?,     -- if true, Discover+InitAll+StartAll in new()
	log: boolean?,           -- enable basic logging
}

local function shallowCopy(t)
	local c = {}
	for k,v in pairs(t) do c[k] = v end
	return c
end

local function safeRequire(mod: ModuleScript)
	local ok, res = pcall(require, mod)
	if not ok then
		error(("[Loader] require failed for %s:\n%s"):format(mod:GetFullName(), res))
	end
	return res
end

local function envAllows(defEnv: any, runtimeEnv: string)
	-- defEnv may be nil|"Client"|"Server"|"Shared"
	if defEnv == nil or defEnv == "Shared" then return true end
	return defEnv == runtimeEnv
end

function ServiceLoader.new(opts: Options)
	assert(opts and opts.root and opts.root:IsA("Instance"), "[Loader] opts.root must be an Instance (Folder)")
	local self = setmetatable({}, ServiceLoader)
	self._root = opts.root
	self._env = opts.env or (RunService:IsClient() and "Client" or "Server")
	self._log = opts.log == true
	self._defs = {}                 -- name -> { module, raw, deps, priority, env }
	self._order = {}                -- topologically sorted service names
	self._instances = {}            -- name -> service instance
	self._readySignals = {}         -- name -> BindableEvent for WaitFor
    self._heartbeatConnection = nil -- centralized heartbeat connection
	self._started = false
	if opts.autoStart then
		self:Discover()
		self:InitAll()
		self:StartAll()
	end
	return self
end

function ServiceLoader:_logf(fmt: string, ...)
	if self._log then
		print("[Loader] " .. string.format(fmt, ...))
	end
end

-- Register a single ModuleScript explicitly (optional; usually you just Discover()).
function ServiceLoader:RegisterModule(mod: ModuleScript)
	local raw = safeRequire(mod)
	if type(raw) ~= "table" or type(raw.Name) ~= "string" then
		-- Not a service (no Name) issue a warning.
		warn("[Loader] Module ")
		return
	end
	local name = raw.Name
	if self._defs[name] then
		error(("[Loader] Duplicate service name '%s' at %s"):format(name, mod:GetFullName()))
	end
	local env = raw.Env or raw.Environment or "Shared"
	if not envAllows(env, self._env) then
		self:_logf("Skipping %s (env=%s, runtime=%s)", name, tostring(env), self._env)
		return
	end
	local deps = raw.Dependencies or {}
	assert(type(deps) == "table", ("[Loader] %s.Dependencies must be a table"):format(name))
	local prio = raw.Priority or 0

	self._defs[name] = {
		module = mod,
		raw = raw,           -- the returned table from require(mod)
		deps = deps,
		priority = prio,
		env = env,
	}
	self:_logf("Registered %s", name)
end

-- Discover all ModuleScripts under root (Descendants).
function ServiceLoader:Discover()
	for _, inst in ipairs(self._root:GetDescendants()) do
		if inst:IsA("ModuleScript") then
			self:RegisterModule(inst)
		end
	end
	self:_topoSort()
end

-- Discover ModuleScripts by their CollectionService tag instead checking all descendants of root.
-- NOTE: This is an alternative to :Discover() and not to be used together with it.
function ServiceLoader:DiscoverByTag(tagName: string)
    self:_logf("Discovering services with tag: %s", tagName)
    for _, inst in ipairs(CollectionService:GetTagged(tagName)) do
        if inst:IsA("ModuleScript") then
            self:RegisterModule(inst)
        end
    end
    self:_topoSort()
end

-- Topological sort by Dependencies (Kahn's algorithm) with priority tie-break.
function ServiceLoader:_topoSort()
	local indeg = {}
	local adj = {}
	local names = {}

	for name, def in pairs(self._defs) do
		indeg[name] = indeg[name] or 0
		adj[name] = adj[name] or {}
		table.insert(names, name)
		for _, dep in ipairs(def.deps) do
			if self._defs[dep] then
				indeg[name] += 1
				adj[dep] = adj[dep] or {}
				table.insert(adj[dep], name)
			else
				-- Missing dep is allowed if it's not a service (e.g., Roblox service) – the service must handle it.
				-- We only graph edges for services managed by this loader.
			end
		end
	end

	-- queue = all nodes with indeg 0, highest priority first
	local function pushZeroes(t)
		table.sort(t, function(a, b)
			local da, db = self._defs[a], self._defs[b]
			local pa, pb = (da and da.priority or 0), (db and db.priority or 0)
			if pa == pb then return a < b end
			return pa > pb
		end)
	end

	local queue = {}
	for name, d in pairs(indeg) do
		if d == 0 then table.insert(queue, name) end
	end
	pushZeroes(queue)

	local order = {}
	while #queue > 0 do
		local node = table.remove(queue, 1)
		table.insert(order, node)
		for _, nb in ipairs(adj[node] or {}) do
			indeg[nb] -= 1
			if indeg[nb] == 0 then
				table.insert(queue, nb)
				pushZeroes(queue) -- keep sorted by priority as we go
			end
		end
	end

	-- Detect cycles
	if #order ~= #names then
		local remaining = {}
		for name, d in pairs(indeg) do
			if d > 0 then table.insert(remaining, name) end
		end
		error(("[Loader] Dependency cycle or missing modules among: %s"):format(table.concat(remaining, ", ")))
	end

	self._order = order
	self:_logf("Start order: %s", table.concat(order, " -> "))
end

-- Create all instances (shallow copy to avoid sharing state across loaders)
function ServiceLoader:InitAll()
	for _, name in ipairs(self._order) do
		local def = self._defs[name]
		if def then
			local base = def.raw
			local inst = shallowCopy(base)
			setmetatable(inst, { __index = base })
			inst._loader = self
			self._instances[name] = inst
		end
	end
	-- Call :Init on all (dependencies exist now)
	for _, name in ipairs(self._order) do
		local s = self._instances[name]
		if s and type(s.Init) == "function" then
			self:_logf("Init %s", name)
			s:Init(self)
		end
	end
end

-- Start all services (after Init).
-- Also provides centralized Heartbeat loop for services that implement :Heartbeat(dt).
function ServiceLoader:StartAll()
    if self._started then return end
    self._started = true
    
    local updateableServices = {}

    for _, name in ipairs(self._order) do
        local s = self._instances[name]
        if s then
            -- 1. Standard Start
            if type(s.Start) == "function" then
                task.spawn(function() s:Start() end)
            end
            
            -- 2. Register for Heartbeat if the method exists
            if type(s.Heartbeat) == "function" then
                table.insert(updateableServices, s)
            end
        end
        
        local be = self._readySignals[name]
        if be then be:Fire() end
    end

    -- 3. The Centralized Heartbeat Loop
    if #updateableServices > 0 then
        self._heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
            for _, service in ipairs(updateableServices) do
                -- Use pcall to ensure one failing service doesn't crash the whole loop
                local success, err = pcall(service.Heartbeat, service, dt)
                if not success then
                    warn(("[Loader] Heartbeat error in %s: %s"):format(service.Name, err))
                end
            end
        end)
    end
end

-- Public APIs ------------------------------------------------------------

function ServiceLoader:Get(name: string)
	local inst = self._instances[name]
	if not inst then
		error(("[Loader] Get('%s') before Discover/Init?"):format(name))
	end
	return inst
end

function ServiceLoader:WaitFor(name: string, timeoutSec: number?)
	if self._started then
		return self:Get(name)
	end
	local be = self._readySignals[name]
	if not be then
		be = Instance.new("BindableEvent")
		self._readySignals[name] = be
	end
	if timeoutSec and timeoutSec > 0 then
		local success = false
		task.delay(timeoutSec, function()
			if not success then be:Fire() end
		end)
		be.Event:Wait()
		success = true
	else
		be.Event:Wait()
	end
	return self:Get(name)
end

function ServiceLoader:DestroyAll()
	-- destroy in reverse order
	for i = #self._order, 1, -1 do
		local name = self._order[i]
		local s = self._instances[name]
		if s and type(s.Destroy) == "function" then
			self:_logf("Destroy %s", name)
			pcall(function() s:Destroy() end)
		end
		self._instances[name] = nil
	end
	self._started = false
end

return ServiceLoader