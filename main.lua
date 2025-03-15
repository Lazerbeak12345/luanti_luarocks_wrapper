-- SPDX-FileCopyrightText: 2025 Lazerbeak12345 on Github and contributors
--
-- SPDX-License-Identifier: MIT

local logging, modlib, core, luarocks_wrapper, dump
	= logging, modlib, core, luarocks_wrapper, dump

local file = modlib.file
local logger = logging.logger()

logger:action"starting..."

local M = {}

-- WARN: DO NOT allow these to be exposed.
local rocks = {}

local function ver_sion(version)
	local ver = version:gsub("-.*", "")
	local sion = version:sub(2 + #ver)
	return ver, sion
end

local register_rock_logger = logger:sublogger"register_rock"
function M.register_rock(name, version, options)
	local sublogger = register_rock_logger
	sublogger:action(("%s-%s"):format(name, version))

	if not options then options = {} end

	local ver, sion = ver_sion(version)

	local c_modname = core.get_current_modname()
	local c_modpath = core.get_modpath(c_modname)

	local name_and_version = name .. "-" .. version
	local name_and_ver = name .. "-" .. ver

	local scm_path_options
	if options.scm then
		scm_path_options = {
			("%s-scm"):format(name),
			("%s-scm-%s"):format(name, sion)
		}
	end

	local rock_path
	if not options.rock_path then
		local path_pattern = "%s/rock/%s/%s"
		-- HACK: I don't actually understand the pattern here,
		--       so here's my guess.
		local path_options = {
			name,
			name_and_ver,
			name_and_version,
		}
		if options.scm then
			for _, value in ipairs(scm_path_options) do
				path_options[#path_options+1] = value
			end
		end
		for _, package_comp in ipairs(path_options) do
			local path = path_pattern:format(
				c_modpath,
				name_and_version,
				package_comp
			)
			if file.exists(path) then
				rock_path = path
				break
			end
		end
	else
		rock_path = ("%s/rock/%s"):format(
			c_modpath,
			options.rock_path
		)
	end
	sublogger:assert(
		type(rock_path) == "string",
		"could not find path of rock"
	)
	local rockspec_path
	do
		local path_pattern = "%s/%s.rockspec"
		local path_options = { name_and_version }
		if options.scm then
			for _, value in ipairs(scm_path_options) do
				path_options[#path_options+1] = value
			end
		end
		for _, rockspec_name in ipairs(path_options) do
			rockspec_path = path_pattern:format(
				rock_path,
				rockspec_name
			)
		end
	end
	sublogger:assert(
		file.exists(rockspec_path),
		"could not find path of rockspec"
	)

	sublogger:verbose(rockspec_path)

	local read = sublogger:assert(loadfile(rockspec_path))
	local rockspec = {}
	setfenv(read, setmetatable({}, {
		__index = {},
		__newindex = rockspec
	}))
	sublogger:assert(pcall(read))

	options.name = name
	options.rock_path = rock_path
	options.rockspec = rockspec
	if not options.ENV then
		options.ENV = setmetatable({}, M.ENV_mt)
	end
	M.register_fake_rock(name, version, options)
end

local mt_mods_that_registered_rocks = {}

local register_fake_rock_logger = logger:sublogger"register_fake_rock"
function M.register_fake_rock(name, version, options)
	local sublogger = register_fake_rock_logger
	sublogger:action(("%s-%s"):format(name, version))

	local _, sion = ver_sion(version)

	local c_modname = core.get_current_modname()
	do
		local prev_rock = mt_mods_that_registered_rocks[c_modname]
		local rock, mod
		if prev_rock then
			rock = prev_rock.rock
			mod = prev_rock.mod
		end
		sublogger:assert(
			prev_rock == nil,
			(
				"Do not bundle more than one rock per mod!"..
				" Use a modpack."..
				" Previous rock was %q registered by %q"
			):format(rock, mod)
		)
		mt_mods_that_registered_rocks[c_modname] = {
			rock = name,
			mod = c_modname,
		}
	end

	if options.insecure_require then
		sublogger:assert(
			type(options.transform) == "function",
			"If insecure mode is used, you MUST provide a transformer. To quote the luanti docs, "..
			"DO NOT ALLOW ANY OTHER MODS TO ACCESS THE RETURNED ENVIRONMENT, STORE IT IN A LOCAL VARIABLE!"
		)
		local fake_require = options.ENV.require
		rawset(options.ENV, "require", function (...)
			local success, fake_rock = pcall(fake_require, ...)
			if success then return fake_rock end
			return options.transform(
				options.insecure_require(...)
			)
		end)
		options.insecure_require = nil -- keep it as an indirect reference for as long as possible.
		options.transform = nil -- Don't transform it later
	end

	local rockspec = options.rockspec
	-- Now that we've loaded the rockspec, we must validate it.
	-- There's a few rocks which we can't support, unfortunatly,
	-- also we need some sanity checks.
	sublogger:assert(
		(rockspec.rockspec_format == nil) or
		rockspec.rockspec_format == "1.0",
		(
			"only version 1.0 rockspecs supported, got %s"
		):format(rockspec.rockspec_format)
	)
	sublogger:assert(
		rockspec.version == version or
		(options.scm and (
			rockspec.version == "scm" or
			rockspec.version == ("scm-%s"):format(sion)
		)),
		("rockspec package version did not match %s ~= %s"):format(rockspec.version, version)
	)
	sublogger:assert(
		rockspec.external_dependencies == nil,
		"rockspec may not depend on external dependencies"
	)
	sublogger:assert(
		rockspec.build == nil or
		rockspec.build.type == "builtin" or
		rockspec.build.type == "none",
		"rockspec mut not require a build, or use builtin"
	)
	-- TODO: use package_.preload instead
	local module_names = {}
	if type(rockspec.build) == "table" and
		rockspec.build.type == "builtin"
	then
		sublogger:assert(
			rockspec.build.platforms == nil,
			"rockspec must not use platform specific build code"
		)
		local rbmt = type(rockspec.build.modules)
		sublogger:assert(
			rbmt == "table",
			(
				"rockspec build type builtin requires a modules table %s"
			):format(rbmt)
		)
		for key, value in pairs(rockspec.build.modules) do
			sublogger:assert(
				type(value) == "string",
				("build.modules[%q] = %s must be a lua path"):format(
					key,
					dump(value)
				)
			)
			sublogger:assert(
				value:find"^.*%.lua" ~= nil,
				"rockspec builtin sources may only be lua files",
				key, value
			)
			module_names[#module_names+1] = key
		end
	else
		module_names[#module_names+1] = name
		sublogger:raise("can't do this rock build type!", rockspec.build)
	end
	-- TODO: assert on dependencies

	for _, module_name in ipairs(module_names) do
		rocks[module_name] = options
	end
end

-- Specifically unavailable:
-- - loadlib
-- - cpath
-- TODO: lock this down
local package_ = {
	loaded = {},
	searchpath = package.searchpath,
	searchers = {},
	preload = {},
	config = package.config,
	path = {},
}

local req
local require_logger = logger:sublogger"require"
function M.require(path)
	if package_.loaded[path] then return package_.loaded[path] end
	rawset(package_.loaded, path, req(path))
	return package_.loaded[path]
end

-- TODO: use package_.searchers
-- TODO: use package_.preload
-- TODO: use package_.path
function req(path)
	local sublogger = require_logger
	local rock_options = sublogger:assert(
		rocks[path],
		("Could not find lua rock by path %s"):format(path)
	)

	local rockspec = rock_options.rockspec
	local rock_path = rock_options.rock_path

	local filepath
	if rockspec.build and rockspec.build.type == "builtin" then
		local module = rockspec.build.modules[path]
		filepath = ("%s/%s"):format(rock_path, module)
	else
		sublogger:raise"other build types not supported"
	end

	sublogger:assert(rock_options.ENV, "must have ENV!")
	local read = sublogger:assert(loadfile(filepath, "t"))
	setfenv(read, rock_options.ENV)
	local result = read()
	if rock_options.transform then
		result = rock_options.transform(result)
	end
	return result
end

M.ENV_mt = {}
M.ENV_mt.__index = {
	require = M.require,
	package = package_,
	arg = {}, -- no command line arguments! :)
}

M.ENV_extra_mts = {}
M.ENV_extra_loggers = {}

for global_key, global_subkey_list in pairs{
	table = {
		"remove",
		"sort",
		"concat",
		--"unpack", -- not in luanti
		--"pack", -- not in luanti
		"insert",
		"move",
	},
	string = {
		"byte",
		"char",
		"match",
		"sub",
		"reverse",
		"gmatch",
		"format",
		--"packsize", -- not in luanti
		"find",
		"rep",
		--"unpack", -- not in luanti
		--"pack", -- not in luanti
		"dump",
		"upper",
		"gsub",
		"lower",
		"len",
	},
	math = {
		"atan2",
		"rad",
		"cosh",
		"modf",
		"frexp",
		"sqrt",
		"min",
		"ldexp",
		"ceil",
		"sin",
		"log10",
		"max",
		"abs",
		"atan",
		"random",
		"tan",
		"exp",
		--"ult", -- not in luanti
		"log",
		"cos",
		"deg",
		--"tointeger", -- not in luanti
		"sinh",
		"asin",
		"acos",
		"pow",
		"tanh",
		--"mininteger", -- not in luanti
		--"type", -- not in luanti
		--"maxinteger", -- not in luanti
		"huge",
		"fmod",
		"floor",
		"pi",
		"randomseed",
	},
	os = {
		"getenv",
		"time",
		--"execute", -- not in luanti
		"difftime",
		"remove",
		"rename",
		"clock",
		--"tmpname", -- not in luanti
		"setlocale",
		--"exit", -- not in luanti
		"date",
	},
	--[[utf8 = { -- not in luanti
		"char",
		"charpattern",
		"codes",
		"codepoint",
		"len",
		"offset"
	}]]
	debug = {
		"debug",

		--"getmetatable", -- not in luanti
		--"setmetatable", -- not in luanti

		"sethook",
		"gethook",

		--"getlocal", -- not in luanti
		--"setlocal", -- not in luanti

		--"getuservalue", -- not in luanti
		--"setuservalue", -- not in luanti

		"traceback",

		--"setcstacklimit", -- unclear docs, deprecated, not in luanti

		--"getupvalue", -- not in luanti
		--"setupvalue", -- not in luanti
		"upvalueid",
		--"upvaluejoin", -- not in luanti

		--"getregistry", -- not in luanti

		"getinfo",
	},
	coroutine = {
		--"close", -- not in luanti
		"create",
		"isyieldable",
		"resume",
		"running",
		"status",
		"wrap",
		"yield",
	},
	io = {
		"close",
		"flush",
		"input",
		"lines",
		"open",
		"output",
		--"popen", -- not in luanti
		"read",
		--"tmpfile", -- not in luanti
		"type",
		"write",
	},
} do
	local obj = {}
	M.ENV_mt.__index[global_key] = obj

	local g_obj = _G[global_key]

	local sublogger = logger:sublogger("extras." .. global_key)
	M.ENV_extra_loggers[global_key] = sublogger

	local mt = {}
	M.ENV_extra_mts[global_key] = mt

	function mt.__newindex()
		sublogger:raise((
			"tried to set index on %s object"
		):format(global_key))
	end

	for _, key in ipairs(global_subkey_list) do
		local value = g_obj[key]
		local t = type(value)
		local allowed = {
			["function"] = true,
			number = true,
		}
		sublogger:assert(
			allowed[t],
			("%s.%s was type %s"):format(
				global_key,
				key,
				t
			)
		)
		obj[key] = value
	end

	setmetatable(obj, mt)
end

for _, key in ipairs{
	"rawget",
	"rawset",
	"rawequal",
	-- "rawlen", -- not in luanti
	"setmetatable",
	"getmetatable",

	"next",
	"pairs",
	"ipairs",

	"unpack",
	"select",

	"pcall",
	"xpcall",
	"assert",
	"error",
	-- "warn", -- not in luanti
	"print",

	"type",

	"tostring",
	"tonumber",

	"load",
	"loadfile",
	"dofile",

	"collectgarbage",

	"_VERSION",
} do
	local value = _G[key]
	local t = type(value)
	local allowed = {
		["function"] = true,
		string = true,
	}
	logger:assert(
		allowed[t],
		("%s was type %s"):format(
			key,
			t
		)
	)
	M.ENV_mt.__index[key] = value
end

local m_mt = {}
m_mt.__metatable = "Don't modify the metatable with getmetatable either, smartypants"
function m_mt.__newindex()
	logger:raise[[n

		Since this mod may handle insecure environment functions, you MUST NOT override functions in this library.

		Should you find it possible, I consider it a serious security problem.
	]]
end
function m_mt.__index(_, key)
	return M[key]
end
setmetatable(luarocks_wrapper, m_mt)

