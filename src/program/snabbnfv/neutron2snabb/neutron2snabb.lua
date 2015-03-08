module(..., package.seeall)

local lib  = require("core.lib")
local json = require("lib.json")
local usage = require("program.snabbnfv.neutron2snabb.README_inc")

function run (args)
   if #args ~= 2 and #args ~= 3 then
      print(usage) main.exit(1)
   end
   create_config(unpack(args))
end

-- Create a Snabb Switch traffic process configuration.
--
-- INPUT_DIR contains the Neutron database dump.
--
-- OUTPUT_DIR will be populated with one file per physical_network.
-- The file says how to connect Neutron ports with provider VLANs.
--
-- HOSTNAME is optional and defaults to the local hostname.
function create_config (input_dir, output_dir, hostname)
   local hostname = hostname or gethostname()
   local segments = parse_csv(input_dir.."/ml2_network_segments.txt",
                              {'id', 'network_id', 'network_type', 'physical_network', 'segmentation_id'},
                              'network_id')
   local networks = parse_csv(input_dir.."/networks.txt",
                              {'tenant_id', 'id', 'name', 'status', 'admin_state_up', 'shared'},
                              'id')
   local ports = parse_csv(input_dir.."/ports.txt",
                           {'tenant_id', 'id', 'name', 'network_id', 'mac_address', 'admin_state_up', 'status', 'device_id', 'device_owner'},
                           'id')
   local port_bindings = parse_csv(input_dir.."/ml2_port_bindings.txt",
                                   {'id', 'host', 'vif_type', 'driver', 'segment', 'vnic_type', 'vif_details', 'profile'},
                                   'id')
   local secrules = parse_csv(input_dir.."/securitygrouprules.txt",
                              {'tenant_id', 'id', 'security_group_id', 'remote_group_id', 'direction', 'ethertype', 'protocol', 'port_range_min', 'port_range_max', 'remote_ip_prefix'},
                              'security_group_id', true)
   local secbindings = parse_csv(input_dir.."/securitygroupportbindings.txt",
                                 {'port_id', 'security_group_id'},
                                 'port_id')
   -- Compile zone configurations.
   local zones = {}
   for _, port in pairs(ports) do
      local binding = port_bindings[port.id]
      -- If the port is a 'snabb' port, lives on our host and is online
      -- then we compile its configuration.
      if binding.driver == "snabb" then
         local vif_details = json.decode(binding.vif_details)
         -- pcall incase the field is missing
         local status, profile = pcall(json.decode, binding.profile)
         profile = profile or {}
         if vif_details.zone_host == hostname then
            local zone_port = vif_details.zone_port
            -- Each zone can have multiple port configurtions.
            if not zones[zone_port] then zones[zone_port] = {} end
            if port.admin_state_up ~= '0' then
               table.insert(zones[zone_port],
                            { vlan = vif_details.zone_vlan,
                              mac_address = port.mac_address,
                              port_id = port.id,
                              ingress_filter = filter(port, secbindings, secrules, 'ingress'),
                              egress_filter = filter(port, secbindings, secrules, 'egress'),
                              gbps = vif_details.zone_gbps,
                              rx_police_gbps = profile.rx_police_gbps,
                              tunnel = tunnel(port, vif_details, profile) })
            end
         end
      end
   end
   -- Save the compiled zone configurations to output_dir.
   for id, ports in pairs(zones) do
      local output_path = output_dir.."/"..id
      lib.store_conf(output_path, ports)
      print("Created " .. output_path)
   end
end

-- Return the packet filter expression.
function filter (port, secbindings, secrules, direction)
   local rules = {}
   direction = direction:lower()
   if secbindings[port.id] then
      for _,r in ipairs(secrules[secbindings[port.id].security_group_id]) do
         if r.remote_group_id == "\\N" then
            if r.direction:lower() == direction then
               local NULL = "\\N" -- SQL null
               local rule = {}
               if r.ethertype        ~= NULL then rule.ethertype        = r.ethertype:lower() end
               if r.protocol         ~= NULL then rule.protocol         = r.protocol:lower()  end
               if r.port_range_min   ~= NULL then rule.dest_port_min    = r.port_range_min    end
               if r.port_range_max   ~= NULL then rule.dest_port_max    = r.port_range_max    end
               if r.remote_ip_prefix ~= NULL then rule.remote_ip_prefix = r.remote_ip_prefix  end
               table.insert(rules, rule)
            end
         end
      end
   end
   if #rules > 0 then return { rules = rules }
                 else return nil end
end

-- Return the L2TPv3 tunnel expresion.
function tunnel (port, vif_details, profile)
   if profile.tunnel_type == "L2TPv3" then
      return { type = "L2TPv3",
               local_ip = vif_details.zone_ip,
               remote_ip = profile.l2tpv3_remote_ip,
               session = profile.l2tpv3_session,
               local_cookie = profile.l2tpv3_local_cookie,
               remote_cookie = profile.l2tpv3_remote_cookie,
               next_hop = profile.l2tpv3_next_hop }
   else return nil end
end

-- Parse FILENAME as a .csv file containing FIELDS.
-- Return a table from the KEY field to a record of all field values.
--
-- Example:
--   parse_csv("Luke	Gorrie	Lua\nJoe	Smith	C\n",
--             {"first", "last", "lang"},
--             "first")
-- Returns:
--   { Luke = { first = "Luke", last = "Gorrie", lang = "Lua" },
--     Joe  = { first = "Joe",  last = "Smith",  lang = "C" }
--   }
function parse_csv (filename, fields, key,  has_duplicates)
   local t = {}
   for line in io.lines(filename) do
      local record = {}
      local words = splitline(line)
      for i = 1, #words do
         record[fields[i]] = words[i]
      end
      if has_duplicates then
         if t[record[key]] == nil then t[record[key]] = {} end
         table.insert(t[record[key]], record)
      else
         t[record[key]] = record
      end
   end
   return t
end

-- Return an array of line's tab-delimited tokens.
function splitline (line)
   local words = {}
   for w in (line .. "\t"):gmatch("([^\t]*)\t") do
      table.insert(words, w)
   end
   return words
end

-- Get hostname.
function gethostname ()
   local hostname = lib.readcmd("hostname", "*l")
   if hostname then return hostname
   else error("Could not get hostname.") end
end

