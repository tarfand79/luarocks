--- Module implementing the LuaRocks "config" command.
-- Queries information about the LuaRocks configuration.
local config_cmd = {}

local persist = require("luarocks.persist")
local cfg = require("luarocks.core.cfg")
local util = require("luarocks.util")
local deps = require("luarocks.deps")
local dir = require("luarocks.dir")

config_cmd.help_summary = "Query information about the LuaRocks configuration."
config_cmd.help_arguments = "(<queryflag> | <key> | <key> <value> --scope=<scope> | <key> --unset --scope=<scope> | )"
config_cmd.help = [[
This command can run in several ways:

* When given a query flag, it prints the value of the specific query

  Accepted query flags are:
   
  --lua-incdir     Path to Lua header files.
   
  --lua-libdir     Path to Lua library files.
   
  --lua-ver        Print Lua version (in major.minor format). e.g. 5.1
   
  --system-config  Location of the system config file.
   
  --user-config    Location of the user config file.
   
  --rock-trees     Rocks trees in use. First the user tree, then the system tree.

  Example: luarocks config --user-config

* When given a configuration key, it prints the value of that key

  --json           Output the value as JSON

  Example: luarocks config lua_interpreter

* When given a configuration key, a value and a scope,
  it overwrites the config file of that scope and replaces the value
  of that key with the given string value. Note that the --scope flag
  is mandatory in this usage.
  
  --scope          May be 'system', 'user' or 'project'.

  Example: luarocks config variables.OPENSSL_DIR /usr/local/openssl --scope=user

* When given a configuration key, a value and a scope,
  it overwrites the config file of that scope and deletes that
  key from the file. Note that the --scope flag
  is mandatory in this usage.
  
  --scope          May be 'system', 'user' or 'project'.

  Example: luarocks config variables.OPENSSL_DIR --unset --scope=user

* When given no arguments, it prints the entire currently active
  configuration, resulting from reading the config files from
  all scopes. Run 'luarocks' with no arguments to see
  the list of config files queried by LuaRocks.

  --json           Output the value as JSON

  Example: luarocks config

]]
config_cmd.help_see_also = [[
	https://github.com/luarocks/luarocks/wiki/Config-file-format
	for detailed information on the LuaRocks config file format.
]]

local function config_file(conf)
   print(dir.normalize(conf.file))
   if conf.ok then
      return true
   else
      return nil, "file not found"
   end
end

local cfg_skip = {
   errorcodes = true,
   flags = true,
   platforms = true,
   root_dir = true,
   upload_servers = true,
}

local function should_skip(k, v)
   return type(v) == "function" or cfg_skip[k]
end

local function cleanup(tbl)
   local copy = {}
   for k, v in pairs(tbl) do
      if not should_skip(k, v) then
         copy[k] = v
      end
   end
   return copy
end

local function traverse_varstring(var, tbl, fn, missing_parent)
   local k, r = var:match("^%[([0-9]+)%]%.(.*)$")
   if k then
      k = tonumber(k)
   else
      k, r = var:match("^([^.[]+)%.(.*)$")
      if not k then
         k, r = var:match("^([^[]+)(%[.*)$")
      end
   end
   
   if k then
      if not tbl[k] and missing_parent then
         missing_parent(tbl, k)
      end

      if tbl[k] then
         return traverse_varstring(r, tbl[k], fn, missing_parent)
      else
         return nil, "Unknown entry " .. k
      end
   end

   local i = var:match("^%[([0-9]+)%]$")
   if i then
      var = tonumber(i)
   end
   
   return fn(tbl, var)
end

local function print_json(value)
   local json_ok, json = util.require_json()
   if not json_ok then
      return nil, "A JSON library is required for this command. "..json
   end

   print(json.encode(value))
end

local function print_entry(var, tbl, is_json)
   return traverse_varstring(var, tbl, function(t, k)
      if not t[k] then
         return nil, "Unknown entry " .. k
      end
      local val = t[k]

      if not should_skip(var, val) then
         if is_json then
            print_json(val)
         else
            persist.write_value(io.stdout, val)
         end
      end
      return true
   end)
end

local function write_entry(var, val, scope, do_unset)
   local conf = cfg.which_config()
   if scope == "project" and not conf.project then
      return nil, "Current directory is not part of a project. You may want to run `luarocks init`."
   end
   
   local tbl, err = persist.load_config_file_if_basic(conf[scope].file, cfg)
   if not tbl then
      return nil, err
   end

   traverse_varstring(var, tbl, function(t, k)
      if do_unset then
         t[k] = nil
      else
         t[k] = val
      end
      return true
   end, function(p, k)
      p[k] = {}
   end)

   local ok, err = persist.save_from_table(conf[scope].file, tbl)
   if ok then
      if do_unset then
         print(("Removed %s from %s"):format(var, conf[scope].file))
      else
         print(("Wrote %s = %q to %s"):format(var, val, conf[scope].file))
      end
      return true
   else
      return nil, err
   end
end

--- Driver function for "config" command.
-- @return boolean: True if succeeded, nil on errors.
function config_cmd.command(flags, var, val)
   deps.check_lua(cfg.variables)
   if flags["lua-incdir"] then
      print(cfg.variables.LUA_INCDIR)
      return true
   end
   if flags["lua-libdir"] then
      print(cfg.variables.LUA_LIBDIR)
      return true
   end
   if flags["lua-ver"] then
      print(cfg.lua_version)
      return true
   end
   local conf = cfg.which_config()
   if flags["system-config"] then
      return config_file(conf.system)
   end
   if flags["user-config"] then
      return config_file(conf.user)
   end
   if flags["rock-trees"] then
      for _, tree in ipairs(cfg.rocks_trees) do
      	if type(tree) == "string" then
      	   util.printout(dir.normalize(tree))
      	else
      	   local name = tree.name and "\t"..tree.name or ""
      	   util.printout(dir.normalize(tree.root)..name)
      	end
      end
      return true
   end

   if var then
      if val or flags["unset"] then
         if not flags["scope"] then
            return nil, "When setting a configuration option, you must set the scope with --scope=<system|user|project>"
         end
         local scope = flags["scope"]
         if scope ~= "system" and scope ~= "user" and scope ~= "local" and scope ~= "project" then
            return nil, "Valid values for scope are: system, user, project"
         end
         
         -- accept --scope=local as an alias for --scope=user
         if scope == "local" then
            scope = "user"
         end
   
         return write_entry(var, val, scope, flags["unset"])
      else
         return print_entry(var, cfg, flags["json"])
      end
   end

   local cleancfg = cleanup(cfg)
   
   if flags["json"] then
      print_json(cleancfg)
      return true
   else
      print(persist.save_from_table_to_string(cleancfg))
      return true
   end
end

return config_cmd
