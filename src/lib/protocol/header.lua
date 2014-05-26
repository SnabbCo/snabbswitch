-- Protocol header base class
--
-- This is an abstract class (should not be instantiated)
--
-- Derived classes must implement the following class variables
--
-- _name          a string that describes the header type in a
--                human readable form
--
-- _header_type   a constructor for the C type object that stores
--                the actual header.  Typically the result of
--                ffi.typeof("struct ...")
--
-- _header_ptr_type a C type object for the pointer to the header
--                  type, i.e. ffi/typeof("$*", _header_type)
--                  This is pre-defined here for performance.
--
-- _ulp           a table that holds information about the "upper
--                layer protocols" supported by the header.  It
--                contains two keys
--                  method   the name of the method of the header
--                           class whose result identifies the ULP
--                           and is used as key for the class_map
--                           table
--                  class_map a table whose keys must represent
--                            valid return values of the instance
--                            method given by the 'method' name
--                            above.  The corresponding value must
--                            be the name of the header class that
--                            parses this particular ULP
--
-- For example, an ethernet header could use
--
-- local ether_header_t = ffi.typeof[[
-- struct {
--    uint8_t  ether_dhost[6];
--    uint8_t  ether_shost[6];
--    uint16_t ether_type;
-- } __attribute__((packed))
-- ]]
--
-- ethernet._name = "ethernet"
-- ethernet._header_type = ether_header_t
-- ethernet._header_ptr_type = ffi.typeof("$*", ether_header_t)
-- ethernet._ulp = { 
--    class_map = { [0x86dd] = "lib.protocol.ipv6" },
--    method    = 'type' }
--
-- In this case, the ULP is identified by the "type" method, which
-- would return the value of the ether_type element.  In this example,
-- only the type value 0x86dd is defined, which is mapped to the class
-- that handles IPv6 headers.
--
-- Header-dependent initializations can be handled by overriding the
-- standard constructor, e.g.
--
-- function ethernet:new (config)
--    local o = ethernet:superClass().new(self)
--    o:dst(config.dst)
--    o:src(config.src)
--    o:type(config.type)
--    return o
-- end
--
-- Protocol headers with a variable format can be handled with a
-- little extra work as follows.
--
-- The class for such a protocl defines just the alternative that can
-- be considered to be the "fundamental" header.  It must be
-- sufficient for the new_from_mem() method to determine the actual
-- header.
--
-- The standard constructors will initialize the header instance with
-- the fundamental type.  The protocol class must override both
-- constructor methods to determine the actual header, either from the
-- configuration or the chunk of memory for the new() and
-- new_from_mem() methods, respectively.  The important part is that
-- the constructors must override the _header* class variables in the
-- header instance.  See lib/protocol/gre.lua for an example of how
-- this can look like.

module(..., package.seeall)
local ffi = require("ffi")

local header = subClass(nil)

-- Class methods

-- The standard constructor creates a new ctype object for the header.
function header:new ()
   local o = header:superClass().new(self)
   o._header = self._header_type()
   return o
end

-- This alternative constructor creates a protocol header from a chunk
-- of memory by "overlaying" a header structure.
function header:new_from_mem (mem, size)
   local o = header:superClass().new(self)
   -- Using the class variables here does the right thing even if the
   -- instance is recycled
   assert(ffi.sizeof(self._header_type) <= size)
   o._header = ffi.cast(self._header_ptr_type, mem)[0]
   return o
end

-- Instance methods

function header:header ()
   return self._header
end

function header:sizeof ()
   return ffi.sizeof(self._header_type)
end

-- default equality method, can be overriden in the ancestors
function header:eq (other)
   return ffi.string(self._header, self:sizeof()) == ffi.string(other._header,self:sizeof())
end

-- Copy the header to some location in memory (usually a packet
-- buffer).  The caller must make sure that there is enough space at
-- the destination.
function header:copy (dst)
   ffi.copy(dst, self._header, ffi.sizeof(self._header))
end

-- Create a new protocol instance that is a copy of this instance.
-- This is horribly inefficient and should not be used in the fast
-- path.
function header:clone ()
   local header = self._header_type()
   local sizeof = ffi.sizeof(header)
   ffi.copy(header, self._header, sizeof)
   return self:class():new_from_mem(header, sizeof)
end

-- Return the class that can handle the upper layer protocol or nil if
-- the protocol is not supported or the protocol has no upper-layer.
function header:upper_layer ()
   local method = self._ulp.method
   if not method then return nil end
   local class = self._ulp.class_map[self[method](self)]
   if class then
      if package.loaded[class] then
	 return package.loaded[class]
      else
	 return require(class)
      end
   else
      return nil
   end
end

return header
