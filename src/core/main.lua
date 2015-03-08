module(...,package.seeall)

-- Default to not using any Lua code on the filesystem.
-- (Can be overridden with -P argument: see below.)
package.path = ''

local STP = require("lib.lua.StackTracePlus")
local ffi = require("ffi")
local zone = require("jit.zone")
local lib = require("core.lib")
local C   = ffi.C
-- Load ljsyscall early to help detect conflicts
-- (e.g. FFI type name conflict between Snabb and ljsyscall)
require("syscall")

require("lib.lua.strict")
require("lib.lua.class")

-- Reserve names that we want to use for global module.
-- (This way we avoid errors from the 'strict' module.)
_G.config, _G.engine, _G.memory, _G.link, _G.packet, _G.timer,
   _G.main = nil

ffi.cdef[[
      extern int argc;
      extern char** argv;
]]

_G.developer_debug = false
debug_on_error = false

function main ()
   zone("startup")
   require "lib.lua.strict"
   initialize()
   local program, args = parse_command_line()
   parameters = args
   if not program then
      print("Usage: snabb <PROGRAM> [ARGS]...")
      os.exit(1)
   end
   if not lib.have_module(modulename(program)) then
      print(programname(program) .. ": unrecognized program name")
      os.exit(1)
   end
   require(modulename(program)).run(parameters)
end

-- programname("nfv-sync-master.2.0") => "nfv-sync-master"
function programname (program) 
   return string.match(program, "([^/]+)$")
end
-- modulename("nfv-sync-master.2.0") => "program.nfv.nfv_sync_master")
function modulename (program) 
   program = programname(string.gsub(program, "-", "_"))
   return ("program.%s.%s"):format(program, program)
end

-- Return two values: program and parameters.
--
-- Program is the name of the program to run. For example 'snsh' or
-- 'packetblaster'.
function parse_command_line ()
   local commandline = {}
   for i = 0, C.argc - 1 do 
      table.insert(commandline, ffi.string(C.argv[i]))
   end
   local program = table.remove(commandline, 1)
   if programname(program) == 'snabb' then
      program = table.remove(commandline, 1)      
   end
   return program, commandline
end

function exit (status)
   os.exit(status)
end

--- Globally initialize some things. Module can depend on this being done.
function initialize ()
   require("core.lib")
   require("core.clib_h")
   require("core.lib_h")
   if C.geteuid() ~= 0 then
      print("error: snabb has to run as root.")
      os.exit(1)
   end
   -- Global API
   _G.config = require("core.config")
   _G.engine = require("core.app")
   _G.memory = require("core.memory")
   _G.link   = require("core.link")
   _G.packet = require("core.packet")
   _G.timer  = require("core.timer")
   _G.main   = getfenv()
end

function handler (reason)
   print(reason)
   print(debug.traceback())
   if debug_on_error then debug.debug() end
   os.exit(1)
end

xpcall(main, handler)

