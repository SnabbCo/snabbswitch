module(..., package.seeall)

local lib = require("core.lib")
local nfvconfig = require("program.snabbnfv.nfvconfig")
local usage = require("program.snabbnfv.traffic.README_inc")
local ffi = require("ffi")
local C = ffi.C

local long_opts = {
   benchmark = "B"
}

function run (args)
   local opt = {}
   local benchpackets
   function opt.B (arg) benchpackets = tonumber(arg) end
   lib.dogetopt(args, opt, "B:", long_opts)
   if #args == 3 then
      local pciaddr, confpath, sockpath = unpack(args)
      if benchpackets then
	 print("snabbnfv traffic starting (benchmark mode)")
	 bench(pciaddr, confpath, sockpath, benchpackets)
      else
	 print("snabbnfv traffic starting")
	 traffic(pciaddr, confpath, sockpath)
      end
   else
      print("Wrong number of arguments: " .. tonumber(#args))
      print()
      print(usage)
      main.exit(1)
   end
end

-- Run in real traffic mode.
function traffic (pciaddr, confpath, sockpath)
   engine.log = true
   local mtime = 0
   while true do
      for i = 1, 60 do
         local mtime2 = C.stat_mtime(confpath)
         if mtime2 ~= mtime then
            print("Loading " .. confpath)
            nfvconfig.apply(nfvconfig.load(confpath, pciaddr, sockpath))
            mtime = mtime2
         end
         engine.main({duration=1})
         -- Flush buffered log messages every 1s
         io.flush()
      end
      -- Report each minute
      engine.report()
   end
end

-- Run in benchmark mode.
function bench (pciaddr, confpath, sockpath, npackets)
   npackets = tonumber(npackets)
   local ports = dofile(confpath)
   local nic = "NIC_"..(config.port_name(ports[1]))
   engine.log = true
   engine.Hz = false

   print("Loading " .. confpath)
   nfvconfig.apply(nfvconfig.load(confpath, pciaddr, sockpath))

   -- From designs/nfv
   local start, packets, bytes = 0, 0, 0
   local done = function ()
      if start == 0 and app.app_table[nic].input.rx.stats.rxpackets > 0 then
         -- started receiving, record time and packet count
         packets = app.app_table[nic].input.rx.stats.rxpackets
         bytes = app.app_table[nic].input.rx.stats.rxbytes
         start = C.get_monotonic_time()
         if os.getenv("NFV_PROF") then
            require("jit.p").start(os.getenv("NFV_PROF"), os.getenv("NFV_PROF_FILE"))
            main.profiling = true
         else
            print("No LuaJIT profiling enabled ($NFV_PROF unset).")
         end
         if os.getenv("NFV_DUMP") then
            require("jit.dump").start(os.getenv("NFV_DUMP"), os.getenv("NFV_DUMP_FILE"))
            main.dumping = true
         else
            print("No LuaJIT dump enabled ($NFV_DUMP unset).")
         end
      end
      return app.app_table[nic].input.rx.stats.rxpackets - packets >= npackets
   end

   app.main({done = done, no_report = true})
   local finish = C.get_monotonic_time()

   local runtime = finish - start
   packets = app.app_table[nic].input.rx.stats.rxpackets - packets
   bytes = app.app_table[nic].input.rx.stats.rxbytes - bytes
   engine.report()
   print()
   print(("Processed %.1f million packets in %.2f seconds (%d bytes; %.2f Gbps)"):format(packets / 1e6, runtime, bytes, bytes * 8.0 / 1e9 / runtime))
   print(("Made %s breaths: %.2f packets per breath; %.2fus per breath"):format(lib.comma_value(engine.breaths), packets / engine.breaths, runtime / engine.breaths * 1e6))
   print(("Rate(Mpps):\t%.3f"):format(packets / runtime / 1e6))
end

