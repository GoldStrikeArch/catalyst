defmodule Catalyst.Runtime.IsolatedPermissionPolicyTest do
  use ExUnit.Case, async: false

  alias Catalyst.Extensions.Loader
  alias Catalyst.Runtime.{Generations, IsolatedWorker, PermissionPolicy}

  @host_compile_probe {__MODULE__, :host_compile_probe}

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    directory = Path.join(System.tmp_dir!(), "catalyst-isolated-policy-#{suffix}")
    source_owner = "isolated_policy_source_#{suffix}"
    manifest_owner = "test.isolated-policy-#{suffix}"
    :ok = File.mkdir(directory)
    :persistent_term.erase(@host_compile_probe)

    path = write_extension(directory, suffix, manifest_owner)

    on_exit(fn ->
      Generations.remove_owner(source_owner)
      :persistent_term.erase(@host_compile_probe)
      File.rm_rf(directory)
    end)

    %{path: path, source_owner: source_owner, manifest_owner: manifest_owner, suffix: suffix}
  end

  test "executes outside the host VM and is torn down with its generation", context do
    {_generation, worker, port} = install(context)
    worker_ref = Process.monitor(worker)
    port_ref = Port.monitor(port)

    refute Code.ensure_loaded?(Catalyst.Test.IsolatedRuntimePolicy)
    assert :persistent_term.get(@host_compile_probe, :missing) == :missing

    assert :allow = authorize(:allow)
    assert {:deny, ":isolated_denied"} = authorize(:deny)

    assert :ok = Generations.remove_owner(context.source_owner)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 5_000
    assert_receive {:DOWN, ^port_ref, :port, ^port, _reason}, 5_000
  end

  test "a dead worker fails permission checks closed", context do
    {_generation, worker, port} = install(context)
    port_ref = Port.monitor(port)

    Port.close(port)
    assert_receive {:DOWN, ^port_ref, :port, ^port, _reason}, 5_000
    _ = :sys.get_state(worker)

    assert {:deny, {:permission_policy_exit, _reason}} = authorize(:allow)
  end

  defp install(context) do
    assert {:ok, contribution} = Loader.compile(context.path)

    assert {:ok, generation} =
             Generations.install(context.source_owner, contribution.manifests)

    assert {:ok, worker} = IsolatedWorker.lookup(generation.id, context.manifest_owner)
    assert {:ok, port} = IsolatedWorker.port(worker)
    {generation, worker, port}
  end

  defp authorize(decision) do
    PermissionPolicy.authorize(
      %{type: :tool_call, decision: decision},
      %{type: :agent, session_id: "isolated-policy-session"},
      %{type: :tool},
      %{cwd: "."}
    )
  end

  defp write_extension(directory, suffix, manifest_owner) do
    module = "Catalyst.Test.IsolatedRuntimePolicy"
    path = Path.join(directory, "isolated_policy_#{suffix}.ex")

    source = """
    defmodule #{module} do
      @behaviour Catalyst.Contracts.PermissionPolicy.V1
      :persistent_term.put(#{inspect(@host_compile_probe)}, :worker_only)

      @impl true
      def authorize(%{decision: :allow}, _principal, _resource, _context), do: :allow

      def authorize(_action, _principal, _resource, _context),
        do: {:deny, :isolated_denied}
    end
    """

    manifest = %{
      "api" => 2,
      "id" => manifest_owner,
      "version" => "1.0.0",
      "trust" => "isolated_worker",
      "services" => [
        %{
          "key" => ["agent", "permission_policy", "default"],
          "contract" => ["catalyst.permission-policy", 1],
          "implementation" => module,
          "binding" => "action"
        }
      ]
    }

    :ok = File.write(path, source)
    :ok = File.write(path <> ".manifest.json", Jason.encode!(manifest))
    path
  end
end
