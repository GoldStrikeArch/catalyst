defmodule Catalyst.ExtensionsFixtures do
  @moduledoc """
  Shared fixtures and helpers for the Extensions contract suites
  (`extensions_load_test.exs`, `extensions_rollback_test.exs`,
  `extensions_collision_test.exs`, `extensions_purge_test.exs`).

  Extension *sources* are functions returning strings; probe callbacks inside
  generated sources report to the test through persistent-term keys of the
  shape `{Catalyst.ExtensionsFixtures, :some_parent}` — use `put_parent!/1`
  to register the current test process under such a key.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Catalyst.Extensions
  alias Catalyst.Hooks

  @doc "Create the live extensions dir and remove it on exit (per-test setup)."
  @spec setup_extensions_dir() :: :ok
  def setup_extensions_dir do
    await_bootstrap!()
    File.mkdir_p!(Extensions.dir())
    on_exit(fn -> File.rm_rf!(Extensions.dir()) end)
    :ok
  end

  @doc """
  Wait for bootstrap and older serialized loads before mutating the shared directory.

  A test that restarts `Catalyst.Extensions` can leave its caller-independent
  bootstrap workflow running after the test process exits. Ordinary lifecycle
  tests must not place their fixtures where that older workflow can discover
  them.
  """
  @spec await_bootstrap!() :: :ok
  def await_bootstrap! do
    await_bootstrap!(500)
    Extensions.locked(fn -> :ok end)
  end

  defp await_bootstrap!(0) do
    raise "extension bootstrap did not quiesce before fixture setup"
  end

  defp await_bootstrap!(attempts) do
    case bootstrap_complete?() do
      true ->
        :ok

      false ->
        receive do
        after
          10 -> await_bootstrap!(attempts - 1)
        end
    end
  end

  defp bootstrap_complete? do
    case Process.whereis(Extensions) do
      nil -> false
      pid -> match?(%{bootstrap: :complete}, :sys.get_state(pid))
    end
  catch
    :exit, _reason -> false
  end

  @doc "Write an extension source into the live extensions dir; returns its path."
  @spec write_ext(String.t(), String.t()) :: Path.t()
  def write_ext(name, source) do
    path = Path.join(Extensions.dir(), name <> ".ex")
    File.write!(path, source)
    path
  end

  @doc "Register the test process under `{#{inspect(__MODULE__)}, key}` (erased on exit)."
  @spec put_parent!(atom()) :: :ok
  def put_parent!(key) do
    :persistent_term.put({__MODULE__, key}, self())
    on_exit(fn -> :persistent_term.erase({__MODULE__, key}) end)
    :ok
  end

  @doc "The `:before_tool_call` hooks registered by `owner`."
  @spec owner_hooks(String.t()) :: [map()]
  def owner_hooks(owner) do
    Hooks.handlers(:before_tool_call) |> Enum.filter(&(&1.owner == owner))
  end

  @doc "Compile a source string, silencing redefinition warnings."
  @spec capture_log_compile(String.t()) :: [{module(), binary()}]
  def capture_log_compile(source) do
    # Code.compile_string warns when redefining across runs; keep logs quiet.
    {result, _io} = ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)
    result
  end

  defmodule SetupOnlyTool do
    @moduledoc "Registered from an extension's setup/1, never auto-classified."
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "setup_only_tool"
    @impl true
    def description, do: "registered from setup/1"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    @impl true
    def execute(_args, _ctx), do: result("ok")
  end

  defmodule DegradedPurgeTool do
    @moduledoc false
    def name, do: "degraded_purge_tool"
    def description, do: "degraded purge regression fixture"
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    def execute(_args, _ctx), do: %{content: [], details: %{}}
  end

  defmodule CacheProbeTool do
    @moduledoc false
    def name, do: "cache_probe_tool"
    def description, do: "purge cache-invalidation fixture"
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
    def execute(_args, _ctx), do: %{content: [], details: %{}}
  end

  @doc "Tool module source with a configurable module, tool name, and description."
  @spec owned_tool_source(String.t(), String.t(), String.t()) :: String.t()
  def owned_tool_source(module, name, description) do
    """
    defmodule #{module} do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: #{inspect(name)}
      @impl true
      def description, do: #{inspect(description)}
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("ok")
    end
    """
  end

  @doc "Extension that registers the shared `same-owned-provider` api."
  @spec owned_provider_source(atom()) :: String.t()
  def owned_provider_source(identity) do
    """
    defmodule Catalyst.Ext.SameOwnedProvider do
      def identity, do: #{inspect(identity)}
      def stream(_request, _messages, _opts, _emit), do: {:error, :not_implemented}
    end

    defmodule Catalyst.Ext.SameOwnedProviderExtension do
      use Catalyst.Extension

      @impl true
      def setup(api) do
        _ignored =
          Catalyst.ExtensionAPI.register_provider(
            api,
            "same-owned-provider",
            Catalyst.Ext.SameOwnedProvider
          )

        :ok
      end
    end
    """
  end

  @doc "A module defined through a dynamic name, to prove purge finds it."
  @spec rejected_dynamic_module_source() :: String.t()
  def rejected_dynamic_module_source do
    """
    dynamic_module = Module.concat(["Catalyst", "Ext", "RejectedDynamicHelper"])

    defmodule dynamic_module do
      def marker, do: :must_be_purged
    end

    """
  end

  @doc "Provider extension whose setup optionally hangs after registration."
  @spec timed_provider_source(atom(), boolean()) :: String.t()
  def timed_provider_source(identity, hang?) do
    after_registration =
      case hang? do
        true ->
          """
          send(
            :persistent_term.get({Catalyst.ExtensionsFixtures, :timed_collision_parent}),
            :timed_collision_recorded
          )

          receive do
            :never -> :ok
          end
          """

        false ->
          ":ok"
      end

    """
    defmodule Catalyst.Ext.TimedOwnedProvider do
      def identity, do: #{inspect(identity)}
      def stream(_request, _messages, _opts, _emit), do: {:error, :not_implemented}
    end

    defmodule Catalyst.Ext.TimedOwnedProviderExtension do
      use Catalyst.Extension

      @impl true
      def setup(api) do
        _ignored =
          Catalyst.ExtensionAPI.register_provider(
            api,
            "timed-owned-provider",
            Catalyst.Ext.TimedOwnedProvider
          )

        #{after_registration}
      end
    end
    """
  end

  @doc "Simple uppercasing tool (auto-classified from source)."
  @spec shout_source() :: String.t()
  def shout_source do
    ~S'''
    defmodule Catalyst.Ext.ShoutTest do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "shout_test"
      @impl true
      def description, do: "Uppercases the given text."
      @impl true
      def parameters do
        %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
      end
      @impl true
      def execute(%{"text" => t}, _ctx), do: result(String.upcase(t))
    end
    '''
  end

  @doc "Tool the agent writes for itself in the self-develop loop test."
  @spec shout_run_source() :: String.t()
  def shout_run_source do
    ~S'''
    defmodule Catalyst.Ext.ShoutRun do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "shout_run"
      @impl true
      def description, do: "Uppercases text."
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
      @impl true
      def execute(%{"text" => t}, _ctx), do: result(String.upcase(t))
    end
    '''
  end

  @doc "Extension exposing optional metadata/0."
  @spec meta_ext_source() :: String.t()
  def meta_ext_source do
    ~S'''
    defmodule Catalyst.Ext.MetaProbe do
      use Catalyst.Extension

      @impl true
      def metadata, do: %{name: "Meta Probe", description: "self-description via metadata/0"}

      @impl true
      def setup(_api), do: :ok
    end
    '''
  end

  @doc "One file contributing both a tool and a before_tool_call hook."
  @spec multikind_source() :: String.t()
  def multikind_source do
    ~S'''
    defmodule Catalyst.Ext.MultiKindTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "mk_tool"
      @impl true
      def description, do: "multi-kind test tool"
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("ok")
    end

    defmodule Catalyst.Ext.MultiKind do
      use Catalyst.Extension
      @impl true
      def setup(api) do
        Catalyst.ExtensionAPI.register_hook(api, :before_tool_call, &Catalyst.Ext.MultiKind.gate/1)
        :ok
      end
      def gate(_ctx), do: :cont
    end
    '''
  end

  @doc "Extension registering `SetupOnlyTool` through the API from setup/1."
  @spec setup_reg_source() :: String.t()
  def setup_reg_source do
    ~S'''
    defmodule Catalyst.Ext.SetupReg do
      use Catalyst.Extension
      @impl true
      def setup(api) do
        {:ok, _} =
          Catalyst.ExtensionAPI.register_tool(
            api,
            Catalyst.ExtensionsFixtures.SetupOnlyTool
          )

        :ok
      end
    end
    '''
  end

  @doc "Top-level source that signals `:compile_parent` and then hangs the compiler."
  @spec compile_hang_source() :: String.t()
  def compile_hang_source do
    ~S'''
    send(:persistent_term.get({Catalyst.ExtensionsFixtures, :compile_parent}), :compile_started)

    receive do
      :never -> :ok
    end

    defmodule Catalyst.Ext.CompileHang do
      def marker, do: :never
    end
    '''
  end

  @doc "Extension whose setup/1 signals `:setup_parent` and then hangs."
  @spec setup_hang_source() :: String.t()
  def setup_hang_source do
    ~S'''
    defmodule Catalyst.Ext.HangingSetup do
      use Catalyst.Extension
      @impl true
      def setup(_api) do
        send(:persistent_term.get({Catalyst.ExtensionsFixtures, :setup_parent}), :setup_started)

        receive do
          :never -> :ok
        end
      end
    end
    '''
  end

  @doc "Simple registered tool used for load/purge round trips."
  @spec ephemeral_source() :: String.t()
  def ephemeral_source do
    ~S'''
    defmodule Catalyst.Ext.EphemeralTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "ephemeral_tool"
      @impl true
      def description, do: "test tool"
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("ok")
    end
    '''
  end

  @doc "Two same-named modules from two owners (module-conflict warning)."
  @spec conflict_source(:a | :b) :: String.t()
  def conflict_source(:a) do
    ~S'''
    defmodule Catalyst.Ext.SharedMod do
      def origin, do: :a
    end
    '''
  end

  def conflict_source(:b) do
    ~S'''
    defmodule Catalyst.Ext.SharedMod do
      def origin, do: :b
    end
    '''
  end

  @doc "Tool for disable/enable round trips."
  @spec toggle_source() :: String.t()
  def toggle_source do
    ~S'''
    defmodule Catalyst.Ext.ToggleTool do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: "toggle_tool"
      @impl true
      def description, do: "disable/enable round-trip test tool"
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}
      @impl true
      def execute(_args, _ctx), do: result("ok")
    end
    '''
  end

  @doc "A file whose second module raises at compile time."
  @spec partial_source() :: String.t()
  def partial_source do
    ~S'''
    defmodule Catalyst.Ext.PartialFirst do
      def marker, do: :first
    end

    defmodule Catalyst.Ext.PartialBoom do
      raise "boom at compile time"
    end
    '''
  end
end
