-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- Apps that implements point-to-point ESP tunnels in transport and tunnel mode
-- for IPv6.

module(..., package.seeall)
local ffi = require("ffi")
local lib = require("core.lib")
local logger = require("lib.logger")
local shm = require("core.shm")
local esp = require("lib.ipsec.esp")
local ipsec_shm = require("lib.ipsec.shm")
local counter = require("core.counter")
local ethernet = require("lib.protocol.ethernet")
local ipv6 = require("lib.protocol.ipv6")
local ipv4 = require("lib.protocol.ipv4")
local siphash = require("lib.hash.siphash")
require("lib.ipsec.shm_h")

Transport = {
   config = {
      spi = {required=true},
      aead = {default="aes-gcm-16-icv"},
      transmit_key = {required=true},
      transmit_salt =  {required=true},
      receive_key = {required=true},
      receive_salt =  {required=true},
      receive_window = {},
      resync_threshold = {},
      resync_attempts = {},
      auditing = {}
   },
   shm = {
      txerrors = {counter}, rxerrors = {counter},
      txdiscards_no_sa = {counter}, rxdiscards_no_sa = {counter}
   }
}

function Transport:new (conf)
   local self = {}
   assert(conf.transmit_salt ~= conf.receive_salt,
          "Refusing to operate with transmit_salt == receive_salt")
   self.encrypt = esp.encrypt:new{
      aead = conf.aead,
      spi = conf.spi,
      key = conf.transmit_key,
      salt = conf.transmit_salt}
   self.decrypt = esp.decrypt:new{
      aead = conf.aead,
      spi = conf.spi,
      key = conf.receive_key,
      salt = conf.receive_salt,
      window_size = conf.receive_window,
      resync_threshold = conf.resync_threshold,
      resync_attempts = conf.resync_attempts,
      auditing = conf.auditing}
   return setmetatable(self, {__index = Transport})
end

function Transport:push ()
   if self.ike_check and self.ike_check() then
      self:maybe_update_keys()
   end

   -- Encapsulation path
   local input = self.input.decapsulated
   local output = self.output.encapsulated
   if self.encrypt then
      -- Parametrization of the call to encapsulate_transport() per
      -- address family would introduce a variability that will
      -- ultimately lead to the formation of a side trace at that
      -- point when traffic of both kinds is present, which will
      -- favour the address family for which the loop happens to get
      -- compiled first.  We work around this by duplicating the code
      -- with calls to fixed functions.
      if self.afi == "ipv4" then
         for _=1,link.nreadable(input) do
            local p = link.receive(input)
            local p_enc = self.encrypt:encapsulate_transport4(p)
            if p_enc then
               link.transmit(output, p_enc)
            else
               packet.free(p)
               counter.add(self.shm.txerrors)
            end
         end
      else
         for _=1,link.nreadable(input) do
            local p = link.receive(input)
            local p_enc = self.encrypt:encapsulate_transport6(p)
            if p_enc then
               link.transmit(output, p_enc)
            else
               packet.free(p)
               counter.add(self.shm.txerrors)
            end
         end
      end
   else
      for _=1,link.nreadable(input) do
         packet.free(link.receive(input))
         counter.add(self.shm.txdiscards_no_sa)
      end
   end

   -- Decapsulation path
   local input = self.input.encapsulated
   local output = self.output.decapsulated
   if self.decrypt then
      if self.afi == "ipv4" then
         for _=1,link.nreadable(input) do
            local p = link.receive(input)
            local p_dec = self.decrypt:decapsulate_transport4(p)
            if p_dec then
               link.transmit(output, p_dec)
            else
               packet.free(p)
               counter.add(self.shm.rxerrors)
            end
         end
      else
         for _=1,link.nreadable(input) do
            local p = link.receive(input)
            local p_dec = self.decrypt:decapsulate_transport6(p)
            if p_dec then
               link.transmit(output, p_dec)
            else
               packet.free(p)
               counter.add(self.shm.rxerrors)
            end
         end
      end
   else
      for _=1,link.nreadable(input) do
         packet.free(link.receive(input))
         counter.add(self.shm.rxdiscards_no_sa)
      end
   end
end

local ip_config = {
   v6 = {
      afi = "ipv6",
      afi_class = ipv6,
      hash_buf = ffi.new[[
         struct {
            uint8_t remote[16];
            uint8_t local[16];
         } __attribute__ ((__packed__))
      ]]
   },
   v4 = {
      afi = "ipv4",
      afi_class = ipv4,
      hash_buf = ffi.new[[
         struct {
            uint8_t remote[4];
            uint8_t local[4];
         } __attribute__ ((__packed__))
      ]]
   }
}

Transport6 = setmetatable(ip_config.v6, {__index = Transport})
Transport4 = setmetatable(ip_config.v4, {__index = Transport})

Transport_IKE = setmetatable(
   {
      config = {
         aead = {default="aes-gcm-16-icv"},
         local_address = {required=true},
         remote_address = {required=true},
         ike_check_interval = {default=4},
         resync_threshold = {},
         resync_attempts = {},
         auditing = {}
      },
   }, { __index = Transport })

function Transport_IKE:new (conf)
   local self = setmetatable(
      {
         ike_check = lib.throttle(conf.ike_check_interval),
         conf = conf,
         logger = logger.new({ module = "ESP-transport-IKE" }),
         -- Cache of current SAs
         sas = { ['in'] = { spi = 0 }, out = { spi = 0 } }
      }, {__index = self})

   -- The hash over the source/destination addresses is used as a
   -- rendez-vous point with the Strongswan IKE daemon in the "ipsec"
   -- subdirectory of SNABB_SHM_ROOT.  The daemon calculates the same
   -- hash over the source and destination traffic-selectors.
   self.hash_buf.remote = self.afi_class:pton(conf.remote_address)
   self.hash_buf['local'] = self.afi_class:pton(conf.local_address)
   -- Static key used by the Strongswan Charon IKE daemon
   local key = ffi.new("uint8_t[16]", 0, 1, 2, 3, 4, 5, 6, 7,
                       8, 9, 10, 11, 12, 13, 14, 15)
   local hash_fn = siphash.make_hash({ size = ffi.sizeof(self.hash_buf),
                                       standard = true, key = key })
   local hash = hash_fn(self.hash_buf)
   local path = "/ipsec/"..bit.tohex(hash)
   self.logger:log(("init %s <-> %s, SA path %s"):
         format(conf.remote_address, conf.local_address, path))
   -- It is crucial that we don't pick up the keys used by a previous
   -- invocation, since that would break the aes-gcm cipher (re-use of
   -- nonces).
   shm.unlink(path)
   self.sa_frame = shm.create_frame(path,
                                    { ['in'] = { ipsec_shm },
                                       out = {ipsec_shm } })

   return self
end

function Transport_IKE:stop ()
   shm.delete_frame(self.sa_frame)
end

function Transport_IKE:maybe_update_key (dir, update_fn)
   local cache = self.sas[dir]
   local sa = self.sa_frame[dir]
   if sa.spi == 0 then
      -- We either did not yet get an SA from IKE or the SA was
      -- deleted by IKE due to a shutdown of the daemon or an explicit
      -- removal.
      update_fn(self)
   elseif cache.spi ~= sa.spi or cache.tstamp ~= sa.tstamp then
      if sa.enc_alg ~= ffi.C.ENCR_AES_GCM_16 then
         self.logger:log(("unsupported algorithm, expected %d, got %d"):
               format(ffi.C.ENCR_AES_GCM_16, sa.enc_alg))
         return nil
      end
      cache.spi = sa.spi
      cache.tstamp = sa.tstamp
      local enc_key = sa.enc_key.aes_gcm_16
      update_fn(self, sa.spi, enc_key.key, enc_key.salt, sa.replay_window)
      self.logger:log(("updating key '%s', SPI 0x%08x(%d)"):
            format(dir, sa.spi, sa.spi))
   end
end

local function update_key_in (self, spi, key, salt, window)
   if spi then
      self.decrypt = esp.decrypt:new{
         aead = self.conf.aead,
         spi = spi,
         key = key,
         salt = salt,
         window_size = window,
         resync_threshold = self.conf.resync_threshold,
         resync_attempts = self.conf.resync_attempts,
         auditing = self.conf.auditing}
      -- Maybe do a JIT flush
   else
      -- No valid inbound SA
      self.decrypt = nil
   end
end

local function update_key_out (self, spi, key, salt)
   if spi then
      self.encrypt = esp.encrypt:new{
         aead = self.conf.aead,
         spi = spi,
         key = key,
         salt = salt}
      -- Maybe do a JIT flush
   else
      -- No valid outbound SA
      self.decrypt = nil
   end
end

function Transport_IKE:maybe_update_keys ()
   self:maybe_update_key('in', update_key_in)
   self:maybe_update_key('out', update_key_out)
end

Transport6_IKE = setmetatable(ip_config.v6, {__index = Transport_IKE})
Transport4_IKE = setmetatable(ip_config.v4, {__index = Transport_IKE})

Tunnel6 = {
   config = {
      self_ip = {required=true},
      nexthop_ip = {required=true},
      spi = {required=true},
      aead = {default="aes-gcm-16-icv"},
      transmit_key = {required=true},
      transmit_salt =  {required=true},
      receive_key = {required=true},
      receive_salt =  {required=true},
      receive_window = {},
      resync_threshold = {},
      resync_attempts = {},
      auditing = {},
      selftest = {default=false}
   },
   shm = {
      txerrors = {counter}, rxerrors = {counter}
   },
   -- https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
   NextHeaderIPv6 = 41
}

function Tunnel6:new (conf)
   local self = {}
   assert(conf.selftest or conf.transmit_salt ~= conf.receive_salt,
          "Refusing to operate with transmit_salt == receive_salt")
   self.encrypt = esp.encrypt:new{
      aead = conf.aead,
      spi = conf.spi,
      key = conf.transmit_key,
      salt = conf.transmit_salt
   }
   self.decrypt = esp.decrypt:new{
      aead = conf.aead,
      spi = conf.spi,
      key = conf.receive_key,
      salt = conf.receive_salt,
      window_size = conf.receive_window,
      resync_threshold = conf.resync_threshold,
      resync_attempts = conf.resync_attempts,
      auditing = conf.auditing
   }
   self.eth = ethernet:new{
      type = 0x86dd -- IPv6
   }
   self.ip = ipv6:new{
      src = ipv6:pton(conf.self_ip),
      dst = ipv6:pton(conf.nexthop_ip),
      next_header = esp.PROTOCOL,
      hop_limit = 64
   }
   return setmetatable(self, {__index = Tunnel6})
end

function Tunnel6:push ()
   -- Encapsulation path
   local input = self.input.decapsulated
   local output = self.output.encapsulated
   while not link.empty(input) do
      local p = link.receive(input)
      if p.length >= ethernet:sizeof() then
         -- Strip Ethernet header
         p = packet.shiftleft(p, ethernet:sizeof())
         -- Encrypt payload
         local p_enc = self.encrypt:encapsulate_tunnel(p, self.NextHeaderIPv6)
         -- Slap on IPv6 and Ethernet headers
         self.ip:payload_length(p_enc.length)
         p_enc = packet.prepend(p_enc, self.ip:header(), ipv6:sizeof())
         p_enc = packet.prepend(p_enc, self.eth:header(), ethernet:sizeof())
         link.transmit(output, p_enc)
      else
         packet.free(p)
         counter.add(self.shm.txerrors)
      end
   end
   -- Decapsulation path
   local input = self.input.encapsulated
   local output = self.output.decapsulated
   while not link.empty(input) do
      local p = link.receive(input)
      if p.length >= ethernet:sizeof() + ipv6:sizeof() then
         -- Strip Ethernet and IPv6 headers
         p = packet.shiftleft(p, ethernet:sizeof() + ipv6:sizeof())
         -- Decrypt payload
         local p_dec, nh = self.decrypt:decapsulate_tunnel(p)
         if p_dec and nh == self.NextHeaderIPv6 then
            -- Slap on new Ethernet header
            p_dec = packet.prepend(p_dec, self.eth:header(), ethernet:sizeof())
            link.transmit(output, p_dec)
            goto next
         end
      end
      -- Handle error
      packet.free(p)
      counter.add(self.shm.rxerrors)
      ::next::
   end
end

function selftest ()
   -- Only testing Tunnel6 because Transport6 is mostly covered in the selftest
   -- of lib.ipsec.esp.
   local basic_apps = require("apps.basic.basic_apps")
   local c = config.new()
   config.app(c, "source", basic_apps.Source)
   config.app(c, "sink", basic_apps.Sink)
   config.app(c, "tunnel", Tunnel6, {
      self_ip = "fc00::1",
      nexthop_ip = "fc00::2",
      spi = 0xdeadbeef,
      transmit_key = "00112233445566778899AABBCCDDEEFF",
      transmit_salt = "00112233",
      receive_key = "00112233445566778899AABBCCDDEEFF",
      receive_salt = "00112233",
      auditing = true,
      selftest = true
   })
   config.link(c, "source.output -> tunnel.decapsulated")
   config.link(c, "tunnel.encapsulated -> tunnel.encapsulated")
   config.link(c, "tunnel.decapsulated -> sink.input")
   engine.configure(c)
   engine.main{duration=0.0001}
   engine.report_links()
   assert(counter.read(engine.app_table.tunnel.shm.rxerrors) == 0,
          "Decapsulation error!")
   print("OK")
end
