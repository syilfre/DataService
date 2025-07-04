--[[
	author : syilfre, july 2025.
	Data service : Inventory & Bank system data service.
	Utilizes session locking, data versioning.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Tools = ServerStorage:WaitForChild("Tools")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local BankRemotes = Remotes:WaitForChild("Bank")

type InventoryItem = { Name: string, Weight: number }
type Transaction   = { Type: string, Amount: number, Reason: string, Target: Player? }
type BalanceEntry  = { Date: string, Balance: number }
type PlayerData = {
	onHand: number,
	onBank: number,
	CreationDate: string,
	PIN: number,
	HighestBalance: number,
	Transactions: { Transaction },
	BalanceHistory: { BalanceEntry },
	Inventory: { InventoryItem },
}

local DataService = {}
DataService._dataStore = DataStoreService:GetDataStore("BKST-014") -- random datastore name with number for testing

local sessionData: { [Player]: PlayerData } = {}
DataService._sessionData = sessionData

DataService._lockTimeout = 60

local DEFAULT_PLAYER_DATA: PlayerData = {
	onHand = 875654,
	onBank = 0,
	CreationDate = DateTime.now():FormatUniversalTime("MM/DD/YYYY", "en-us"),
	PIN = 1234,
	HighestBalance = 0,
	Transactions = {},
	BalanceHistory = {},
	Inventory = {},
}

local function deepClone(original: any): any
	if typeof(original) ~= "table" then return original end
	local copy = {}
	for k, v in pairs(original) do
		copy[k] = deepClone(v)
	end
	return copy
end

local toolInfo = require(ReplicatedStorage.Modules:WaitForChild("ToolInfo"))

local function loadInventory(player: Player, data: PlayerData)
	local folder = player:FindFirstChild("Inventory") or Instance.new("Folder")
	
	folder.Name = "Inventory"
	folder:ClearAllChildren()
	folder.Parent = player
	warn(data.Inventory)
	for _, itemData in ipairs(data.Inventory or {}) do
		print(itemData)
		local template = Tools:FindFirstChild(itemData.Name, true)
		if template then
			local item = template:Clone()
			local weight = item:FindFirstChild("Weight")
			if weight and weight:IsA("NumberValue") then
				weight.Value = itemData.Weight or toolInfo[itemData.Name].Weight
			else
				local w = Instance.new("NumberValue")
				w.Name = "Weight"
				w.Value = itemData.Weight or 5
				w.Parent = item
			end
			item.Parent = folder
		else
			warn("Missing tool in ServerStorage: " .. itemData.Name)
		end
	end
end

local function serializeInventory(player: Player): { InventoryItem }
	local list = {}
	local folder = player:FindFirstChild("Inventory")
	if not folder then return list end
	for _, item in folder:GetChildren() do
		table.insert(list, { Name = item.Name,Weight = toolInfo[item.Name].Weight})
	end
	print(list)
	return list
end

function DataService:GetData(player: Player): PlayerData?
	return self._sessionData[player]
end

function DataService:Save(player: Player)
	local data = self._sessionData[player]
	if not data then return end

	data.Inventory = serializeInventory(player)

	local key = "Player_" .. player.UserId .. "_data"
	local success, err = pcall(function()
		self._dataStore:SetAsync(key, data)
		self._dataStore:RemoveAsync("Player_" .. player.UserId)
	end)

	if not success then
		warn("Save failed for", player.Name, err)
	end

	self._sessionData[player] = nil
end

function DataService:Load(player: Player)
	warn('test yo')
	local key = "Player_" .. player.UserId

	local stats = Instance.new("Folder")
	stats.Name = "playerStats"
	stats.Parent = player

	local bank = Instance.new("IntValue")
	bank.Name = "bank_onBank"
	bank.Parent = stats

	local hand = Instance.new("IntValue")
	hand.Name = "bank_onHand"
	hand.Parent = stats

	local success, locked = pcall(function()
		return self._dataStore:UpdateAsync(key, function(current)
			if current and current.lock and os.time() - current.timestamp < self._lockTimeout then
				return nil
			end
			return { lock = true, jobId = game.JobId, timestamp = os.time() }
		end)
	end)

	if not success or not locked then
		player:Kick("Data locked. Rejoin shortly.")
		return
	end

	local data: PlayerData
	local ok, stored = pcall(function()
		return self._dataStore:GetAsync(key .. "_data")
	end)

	if ok and stored then
		data = stored
		for k, v in pairs(DEFAULT_PLAYER_DATA) do
			if data[k] == nil then
				data[k] = typeof(v) == "table" and deepClone(v) or v
			end
		end
	else
		data = deepClone(DEFAULT_PLAYER_DATA)
		data.CreationDate = DateTime.now():FormatUniversalTime("MM/DD/YYYY", "en-us")
		table.insert(data.BalanceHistory, {
			Date = data.CreationDate,
			Balance = 0
		})
	end

	self._sessionData[player] = data
	warn('test is this running? test')
	loadInventory(player, data)

	bank.Value = data.onBank
	hand.Value = data.onHand

	bank.Changed:Connect(function(val)
		if self._sessionData[player] then
			self._sessionData[player].onBank = val
		end
	end)

	hand.Changed:Connect(function(val)
		if self._sessionData[player] then
			self._sessionData[player].onHand = val
		end
	end)

	task.delay(2, function()
		BankRemotes.UpdateTransactions:FireClient(player, data.Transactions, data.CreationDate)
		BankRemotes.UpdateBalanceGraph:FireClient(player, data.BalanceHistory, data.HighestBalance)
	end)
end

function DataService:RecordTransaction(plr: Player, Type: string, Amount: number, Reason: string, Target: Player?)
	assert(Type == "Add" or Type == "Deduct", "Invalid transaction type")
	assert(typeof(Amount) == "number" and Amount > 0, "Amount must be a positive number")
	assert(typeof(Reason) == "string", "Reason must be a string")
	if Reason == "Transfer" then
		assert(Target and Target:IsA("Player"), "Transfer must specify valid Target")
	end

	local data = self._sessionData[plr]
	if not data then return end

	table.insert(data.Transactions, {
		Type = Type,
		Amount = Amount,
		Reason = Reason,
		Target = Target
	})

	table.insert(data.BalanceHistory, {
		Date = DateTime.now():FormatUniversalTime("MM/DD/YYYY", "en-us"),
		Balance = plr.playerStats.bank_onBank.Value
	})

	BankRemotes.UpdateTransactions:FireClient(plr, data.Transactions)
	BankRemotes.UpdateBalanceGraph:FireClient(plr, data.BalanceHistory, data.HighestBalance)
end

function DataService:Init()
	Players.PlayerAdded:Connect(function(player)
		self:Load(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:Save(player)
	end)

	game:BindToClose(function()
		for _, p in ipairs(Players:GetPlayers()) do
			self:Save(p)
		end
		task.wait(2)
	end)

	BankRemotes.PIN.OnServerInvoke = function(plr, change, newPIN)
		assert(typeof(change) == "boolean" or change == nil, "change must be boolean")
		assert(newPIN == nil or typeof(newPIN) == "string" or typeof(newPIN) == "number", "PIN must be string or number")
		local data = self._sessionData[plr]
		if not data then return end

		if change and tonumber(newPIN) and #tostring(newPIN) == 4 then
			if plr.playerStats.bank_onBank.Value >= 1000 then
				data.PIN = tonumber(newPIN)
				plr.playerStats.bank_onBank.Value -= 1000
				self:RecordTransaction(plr, "Deduct", 1000, "PIN Change")
				return true
			else
				return false
			end
		else
			return data.PIN
		end
	end

	BankRemotes.UpdateTransactions.OnServerEvent:Connect(function(plr)
		local data = self._sessionData[plr]
		if data then
			return data.CreationDate
		end
	end)

	script.AddKey.Event:Connect(function(plr, Type, Amount, Reason, Target)
		self:RecordTransaction(plr, Type, Amount, Reason, Target)
	end)
end

return DataService
