defmodule Catalyst.ExtensionsPurgeTest do
  # async: false — Extensions is global, shared, mutable state.
  use ExUnit.Case, async: false

  import Catalyst.ExtensionsFixtures

  alias Catalyst.Extensions
  alias Catalyst.ExtensionsFixtures.CacheProbeTool

  setup do
    setup_extensions_dir()
  end

  test "disable purges + renames the file; load_all keeps it off; enable restores it" do
    on_exit(fn -> Extensions.uninstall("toggle") end)
    path = write_ext("toggle", toggle_source())
    assert {:ok, _summary} = Extensions.load_file(path)
    assert {:ok, _mod} = Extensions.fetch("toggle_tool")

    assert {:ok, disabled} = Extensions.disable("toggle")
    assert disabled == path <> ".disabled"
    assert File.exists?(disabled)
    refute File.exists?(path)
    assert Extensions.fetch("toggle_tool") == :error
    refute Enum.any?(Extensions.list_loaded(), &(&1.owner == "toggle"))
    assert [%{owner: "toggle"}] = Extensions.list_disabled()

    # A full reload (≈ next boot) must not resurrect a disabled extension.
    {:ok, _} = Extensions.load_all()
    assert Extensions.fetch("toggle_tool") == :error

    assert {:ok, summary} = Extensions.enable("toggle")
    assert summary.tools == ["toggle_tool"]
    assert {:ok, _mod} = Extensions.fetch("toggle_tool")
    assert Extensions.list_disabled() == []
  end

  test "disable/enable for an owner with no source file return :no_file" do
    assert {:error, :no_file} = Extensions.disable("no_such_owner")
    assert {:error, :no_file} = Extensions.enable("no_such_owner")
  end

  test "an externally loaded extension is reload-only and cannot be stranded by disable" do
    external_dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst_external_disable_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(external_dir)
    path = Path.join(external_dir, "external_disable.ex")

    File.write!(
      path,
      owned_tool_source(
        "Catalyst.Ext.ExternalDisableTool",
        "external_disable_tool",
        "external"
      )
    )

    on_exit(fn ->
      Extensions.uninstall("external_disable")
      File.rm_rf!(external_dir)
    end)

    assert {:ok, _summary} = Extensions.load_file(path)
    info = Enum.find(Extensions.list_loaded(), &(&1.owner == "external_disable"))
    refute info.managed?

    assert {:error, :external_source} = Extensions.disable("external_disable")
    assert File.regular?(path)
    refute File.exists?(path <> ".disabled")
    assert {:ok, Catalyst.Ext.ExternalDisableTool} = Extensions.fetch("external_disable_tool")
  end

  test "purging an owner invalidates its tool registry metadata cache" do
    owner = "cache_invalidate_owner"
    cache_key = {{Catalyst.Tools.Registry, :definition}, CacheProbeTool}
    on_exit(fn -> Extensions.uninstall(owner) end)

    assert {:ok, _module} = Extensions.register_tool(CacheProbeTool, owner: owner)
    assert :persistent_term.get(cache_key, :missing) != :missing

    assert :ok = Extensions.uninstall(owner)
    assert :persistent_term.get(cache_key, :missing) == :missing
  end

  test "concurrent reseeder registration cannot lose entries" do
    reseeders_key = {Extensions, :reseeders}
    previous = :persistent_term.get(reseeders_key, %{})
    on_exit(fn -> :persistent_term.put(reseeders_key, previous) end)

    funs = for i <- 1..32, do: :"concurrent_reseed_#{i}"

    funs
    |> Task.async_stream(&Extensions.register_reseeder(__MODULE__, &1), timeout: :infinity)
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    registered = :persistent_term.get(reseeders_key, %{})
    assert Enum.all?(funs, &Map.has_key?(registered, {__MODULE__, &1}))
  end
end
