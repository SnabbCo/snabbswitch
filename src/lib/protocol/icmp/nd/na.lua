module(..., package.seeall)
local ffi = require("ffi")
local C = ffi.C
local lib = require("core.lib")
local nd_header = require("lib.protocol.icmp.nd.header")

local na_t = ffi.typeof[[
      struct {
	 uint32_t flags;
      } __attribute__((packed))
]]
local na = subClass(nd_header)

-- Class variables
na._name = "neighbor advertisement"
na._header_type = na_t
na._header_ptr_type = ffi.typeof("$*", na_t)
na._ulp = { method = nil }

-- Class methods

function na:new (target, router, solicited, override)
   local o = na:superClass().new(self)
   o:target(target)
   o:router(router)
   o:solicited(solicited)
   o:override(override)
   return o
end

-- Instance methods

function na:target (target)
   if target ~= nil then
      ffi.copy(self._header.target, target, 16)
   end
   return self._header.target
end

function na:target_eq (target)
   return C.memcmp(target, self._header.target, 16) == 0
end

function na:router (r)
   return lib.bitfield(32, self._header, 'flags', 0, 1, r)
end

function na:solicited (s)
   return lib.bitfield(32, self._header, 'flags', 1, 1, s)
end

function na:override (o)
   return lib.bitfield(32, self._header, 'flags', 2, 1, o)
end

return na
