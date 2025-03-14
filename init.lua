local modlib = modlib

local modlib_minetest = modlib.minetest
local modlib_minetest_mod = modlib_minetest.mod

modlib_minetest_mod.create_namespace()
modlib_minetest_mod.include"main.lua"

if true then
	local logging, core, luarocks_wrapper
		= logging, core, luarocks_wrapper

	local logger = logging.logger()

	luarocks_wrapper.register_rock("fun", "0.1.3-1", {
		rock_path="fun-0.1.3-1/luafun",
		transform = function (fun)
			-- Don't repvovide mt.__call, as we don't want to modify globals in a shared
			-- global env like luanti
			local t = {}
			setmetatable(t, { __index = fun })
			return t
		end
	})
	--[[
	luarocks_wrapper.register_rock("fun", "0.1.3-1", {
		rock_path="fun-0.1.3-1/luafun",
	})
	--]]

	local fun = luarocks_wrapper.require"fun"
	logger:error(fun)
	fun.each(function (...)
		logger:error(...)
	end, fun.take(5, fun.tabulate(math.sin)))

	logger:error(
		fun
			.range(100)
			:map(function(x) return x^2 end)
			:reduce(fun.operator.add, 0)
	)

	core.request_shutdown("finish in 3 seconds!", false, 3)
end
