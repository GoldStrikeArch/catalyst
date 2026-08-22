{:ok, _started} = Application.ensure_all_started(:catalyst)
:ok = Catalyst.Extensions.await_ready()
{:ok, Catalyst.Tools.Read} = Catalyst.Extensions.fetch("read")
:ok = CatalystCli.run(["selftest"])
:ok = Catalyst.Extensions.mark_clean_shutdown()

IO.puts("CATALYST_RELEASE_SMOKE_OK")
