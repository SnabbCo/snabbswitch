module(..., package.seeall)

basic_apps = require ('apps.basic.basic_apps')

function selftest()
   local c = config.new()
   config.cpu(c, 'proc1', {profile='vfl4'})
   config.cpu(c, 'proc2')
   config.app(c, 'source', basic_apps.Source, {size=120, cpu='proc1'})
   config.app(c, 'localsink', basic_apps.Sink, {cpu='proc1'})
   config.app(c, 'sink', basic_apps.Sink, {cpu='proc2'})
   config.link(c, 'source.output -> sink.input')
   config.link(c, 'source.output2 -> localsink.input')
   engine.configure(c)

   engine.main{duration=1, report={showlinks=true, showapps=true}}
end
