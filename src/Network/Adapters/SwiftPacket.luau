--!strict
-- Adapter accepts an installed SwiftPacket library or an existing raw packet table.
local SwiftPacket = {}
function SwiftPacket.Define(library: any, contracts: any): any
	local packets = {}
	-- Preserve contract declaration order on both peers; never derive wire IDs locally.
	for _, contract in contracts do
		local types = {}
		for _, field in contract.Fields do
			local kind = if type(field) == "string" then field else field.Type
			local descriptor = assert(library[kind], `Unsupported SwiftPacket type: {kind}`)
			table.insert(types, descriptor)
		end
		local packet = library(contract.Name, table.unpack(types))
		if contract.RateLimit then
			packet = packet:RateLimit(contract.RateLimit[1], contract.RateLimit[2])
		end
		if contract.ReceiveOn == "Client" then
			packet = packet:Validate(function()
				return false
			end)
		end
		packets[contract.Name] = packet
	end
	return table.freeze(packets)
end
function SwiftPacket.new(packets: any, side: string): any
	local adapter = { EnforcesRateLimit = true }
	function adapter:On(name: string, callback: any): any
		return packets[name][if side == "Server" then "OnServerEvent" else "OnClientEvent"]:Connect(callback)
	end
	function adapter:Send(name: string, values: any, target: any?)
		if target ~= nil then
			packets[name]:FireClient(target, table.unpack(values, 1, values.n))
		else
			packets[name]:Fire(table.unpack(values, 1, values.n))
		end
	end
	return adapter
end
return SwiftPacket
