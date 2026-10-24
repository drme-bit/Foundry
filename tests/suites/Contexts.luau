--!nonstrict
return function(Foundry, t)
	local cases = {}
	local function fails(callback, expected)
		local ok, reason = pcall(callback)
		assert(not ok and tostring(reason):find(expected, 1, true), tostring(reason))
	end
	cases["side constructors support colon and dot calls and isolate applications"] = function()
		local a, b = Foundry:ServerContext(), Foundry.ServerContext()
		local client = Foundry.ClientContext({})
		assert(a ~= b and a:GetSide() == "Server" and client:GetSide() == "Client")
		a:RegisterValue("OnlyA", 12)
		a:Start()
		b:Start()
		client:Start()
		assert(a:Get("OnlyA") == 12)
		fails(function()
			b:Get("OnlyA")
		end, "OnlyA")
		a:Destroy()
		b:Destroy()
		client:Destroy()
	end
	cases["constructors verify runtime and reject conflicting network sides"] = function()
		local server = {
			IsServer = function()
				return true
			end,
			IsClient = function()
				return false
			end,
		}
		local client = {
			IsServer = function()
				return false
			end,
			IsClient = function()
				return true
			end,
		}
		Foundry:ServerContext({ Platform = server }):Destroy()
		Foundry:ClientContext({ Platform = client }):Destroy()
		fails(function()
			Foundry:ClientContext({ Platform = server })
		end, "runtime")
		fails(function()
			Foundry:ServerContext({ Platform = client })
		end, "runtime")
		fails(function()
			Foundry:ServerContext({ Side = "Client" })
		end, "overridden")
		fails(function()
			Foundry:ClientContext({ Network = { Side = "Server" } })
		end, "Network side")
	end
	cases["network side is inferred without changing supplied options"] = function()
		local options = { Network = {
			Contracts = {},
			CreateAdapter = function()
				return {}
			end,
		} }
		local a, b = Foundry:ServerContext(options), Foundry:ClientContext(options)
		assert(options.Side == nil and options.Network.Side == nil)
		a:Start()
		b:Start()
		assert(a:Get("Network")._side == "Server" and b:Get("Network")._side == "Client")
		a:Destroy()
		b:Destroy()
	end
	cases["wrong-side features fail before provider factories and expose failed state"] = function()
		local creates = 0
		local app = Foundry:ClientContext({
			Features = {
				{
					Name = "Secret",
					Side = "Server",
					Providers = {
						{
							Name = "Database",
							Create = function()
								creates += 1
								return {}
							end,
						},
					},
				},
			},
		})
		fails(function()
			app:Start()
		end, "belongs to Server")
		assert(creates == 0 and app:GetState() == "Failed")
		app:Destroy()
		local shared = Foundry:ServerContext({ Features = { { Name = "Common" } } })
		shared:Start()
		shared:Destroy()
	end
	cases["throwing config validators fail before factories with diagnostic errors"] = function()
		local called = false
		local app = Foundry:ServerContext({
			Config = {},
			ConfigSchema = function()
				error("bad checker")
			end,
			Providers = {
				{
					Name = "Never",
					Create = function()
						called = true
						return {}
					end,
				},
			},
		})
		fails(function()
			app:Start()
		end, "bad checker")
		assert(not called and app:GetState() == "Failed")
		app:Destroy()
	end
	if not t then
		return cases
	end
	cases["real t validates strict configuration before startup"] = function()
		local schema = t.strictInterface({ Name = t.string, Limit = t.integer })
		for _, config in { { Name = 3, Limit = 1 }, { Name = "A", Limit = 1, Extra = true } } do
			local app = Foundry:ServerContext({ Config = config, ConfigSchema = schema })
			fails(function()
				app:Start()
			end, "Config validation failed")
			app:Destroy()
		end
		local app = Foundry:ServerContext({ Config = { Name = "A", Limit = 1 }, ConfigSchema = schema })
		app:Start()
		assert(app:Get("Config").Name == "A")
		app:Destroy()
	end
	cases["real t compiles tuples once while preserving wire bounds and nil counts"] = function()
		local compiled = 0
		local types = table.clone(t)
		types.tuple = function(...)
			compiled += 1
			return t.tuple(...)
		end
		local C = Foundry.Network.Contract
		local registry = C.Registry({
			{
				Name = "Data",
				ReceiveOn = "Server",
				Fields = {
					{ Type = "String", MaxLength = 3 },
					"Boolean",
					"F64",
					"U8",
					"U32",
				},
			},
		}, types)
		local definition = registry.Data
		assert(C.Validate(definition, table.pack("abc", true, 1, 255, 4294967295)))
		for _, payload in
			{
				table.pack("long", true, 1, 0, 0),
				table.pack("ok", 1, 1, 0, 0),
				table.pack("ok", true, math.huge, 0, 0),
				table.pack("ok", true, 0 / 0, 0, 0),
				table.pack("ok", true, 1, -1, 0),
				table.pack("ok", true, 1, 256, 0),
				table.pack("ok", true, 1, 0.5, 0),
				table.pack("ok", true, 1, 0, 4294967296),
				table.pack("ok", true, 1, 0, nil),
				table.pack("ok", true, 1, 0, 0, nil),
			}
		do
			assert(not C.Validate(definition, payload))
		end
		assert(compiled == 1)
	end
	cases["semantic t checks and thrown validators reject packets without invoking handlers"] = function()
		for _, check in
			{
				t.tuple(t.literal("allowed")),
				function()
					error("broken checker")
				end,
			}
		do
			local incoming, called = nil, 0
			local adapter = {
				On = function(_, _, callback)
					incoming = callback
					return { Disconnect = function() end }
				end,
			}
			local app = Foundry:ServerContext({
				Types = t,
				Network = {
					Contracts = {
						{ Name = "Test", ReceiveOn = "Server", Fields = { "String" }, Check = check },
					},
					CreateAdapter = function()
						return adapter
					end,
				},
			})
			app:Start()
			local network = app:Get("Network")
			network:On("Test", function()
				called += 1
			end)
			incoming({}, "denied")
			assert(called == 0)
			incoming({}, "allowed")
			local accepts = Foundry.Validation.Check(check, "allowed")
			assert(called == (if accepts then 1 else 0))
			app:Destroy()
		end
	end
	return cases
end
