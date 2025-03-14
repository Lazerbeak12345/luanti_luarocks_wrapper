local logging, modlib, core, luarocks_wrapper, dump
	= logging, modlib, core, luarocks_wrapper, dump

local file = modlib.file
local logger = logging.logger()

logger:action" starting..."

local m = luarocks_wrapper

local rocks = {}

local register_rock_logger = logger:sublogger"register_rock"
function m.register_rock(name, version, options)
	local sublogger = register_rock_logger
	sublogger:debug(name)
	sublogger:debug(version)

	if not options then options = {} end

	local ver = version:gsub("-%d*", "")

	local c_modname = core.get_current_modname()
	local c_modpath = core.get_modpath(c_modname)
	sublogger:debug(c_modname)
	sublogger:debug(c_modpath)

	local name_and_version = name .. "-" .. version
	local name_and_ver = name .. "-" .. ver

	local rock_path
	if not options.rock_path then
		local path_pattern = "%s/rock/%s/%s"
		-- HACK: I don't actually understand the pattern here,
		--       so here's my guess.
		for _, package_comp in ipairs{
			name,
			name_and_ver,
			name_and_version
		} do
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
	local rockspec_path = ("%s/%s.rockspec"):format(
		rock_path,
		name_and_version
	)
	sublogger:assert(file.exists(rockspec_path))

	sublogger:debug(rockspec_path)

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
		options.ENV = setmetatable({}, m.ENV_mt)
	end
	m.register_fake_rock(name, version, options)
end

local mt_mods_that_registered_rocks = {}

local register_fake_rock_logger = logger:sublogger"register_fake_rock"
function m.register_fake_rock(name, version, options)
	local sublogger = register_fake_rock_logger

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
		rockspec.version == version,
		"rockspec package version did not match"
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
function m.require(path)
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

m.ENV_mt = {}
m.ENV_mt.__index = {
	require = m.require,
	package = package_,
	arg = {}, -- no command line arguments! :)
}

m.ENV_extra_mts = {}
m.ENV_extra_loggers = {}

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
	-- will not do debug - debug is insecure
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
	m.ENV_mt.__index[global_key] = obj

	local g_obj = _G[global_key]

	local sublogger = logger:sublogger("extras." .. global_key)
	m.ENV_extra_loggers[global_key] = sublogger

	local mt = {}
	m.ENV_extra_mts[global_key] = mt

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
	m.ENV_mt.__index[key] = value
end

