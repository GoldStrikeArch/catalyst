defmodule Catalyst.Flex.Baseline do
  @moduledoc """
  Normalized, order-independent leak detector for supported runtime seams.

  The detector intentionally ignores the ToolRunner schema-definition cache:
  validated metadata may outlive a purged module by design. All other mutable
  seams exercised by the flexibility tier are represented explicitly.
  """

  import ExUnit.Assertions

  alias Catalyst.Extensions
  alias Catalyst.Flex.Harness
  alias Catalyst.Runtime.Registry, as: Runtime

  @ui_registry Module.concat([CatalystWeb, UI, Registry])
  @shell_live Module.concat([CatalystWeb, ShellLive])
  # Dimensions whose teardown is asynchronous get a bounded retry poll in
  # `assert_clean!/2`: process/registry teardown rides monitor DOWNs, and the
  # tool table refills through the Extensions server's *background* bootstrap
  # replay after a runtime-group restart, so both can transiently lag the
  # baseline without anything having leaked. A real leak still fails at the
  # 1s deadline.
  @async_dimensions [:extension_processes, :sessions, :shell_sessions, :tools]
  @app_env [
    {:catalyst, :home},
    {:catalyst, :auth_path},
    {:catalyst, :extensions_dir},
    {:catalyst, :sessions_root},
    {:catalyst, :system_prompt_path},
    {:catalyst, :prompts_dir},
    {:catalyst, :agents_dir},
    {:catalyst, :boot_marker_path},
    # Keys config/test.exs sets — a flex scenario that flips one of these and
    # forgets to restore it must be caught, like any other seam.
    {:catalyst, :extension_runtime_max_restarts},
    {:catalyst, :codex_live_models},
    {:catalyst, :boot_stable_ms},
    {:catalyst_web, :ui_runtime_max_restarts},
    {:catalyst, :agent_loop},
    {:catalyst, :workflows},
    {:catalyst, :prompt_policy},
    {:catalyst, :prompts},
    {:catalyst, :prompt_policy_timeout},
    {:catalyst, :context_policy},
    {:catalyst, :context_thresholds},
    {:catalyst, :context_policy_timeout},
    {:catalyst, :subagent_max_depth},
    {:catalyst, :subagent_max_concurrent},
    {:catalyst, :subagent_timeout},
    {:catalyst, :provider_cleanup_timeout},
    {:catalyst, :codex_models},
    {:catalyst, :codex_model},
    {:catalyst, :flex_echo_script},
    {:catalyst, :flex_observer_pid},
    {:catalyst, :flex_safe_mode_sentinel},
    {:catalyst, :computer_use},
    {:catalyst, :computer_helper_path},
    {:catalyst, :computer_backend_available},
    {:catalyst, :computer_backend},
    {:catalyst, :computer_screenshot_retain},
    {:catalyst, :shell_session_idle_ms},
    {:catalyst, :shell_session_max},
    {:catalyst_web, :reattach_sessions}
  ]
  @persistent_keys [:current_session, :codex_prefs, :ui_prefs, :machine_prefs]

  @type t :: map()

  @doc "Capture every mutable runtime seam covered by the flexibility proof."
  @spec capture() :: t()
  def capture do
    await_all_observers()

    %{
      tools: tool_snapshot(),
      modules: module_snapshot(),
      loaded: Extensions.list_loaded() |> stable_term(),
      disabled: Extensions.list_disabled() |> stable_term(),
      sources: source_manifest(Extensions.dir()),
      providers: Catalyst.LLM.Registry.list() |> stable_term(),
      prompt_runtime: Catalyst.Prompt.Registry.runtime_entries() |> stable_term(),
      workflow_runtime: Catalyst.Workflow.Registry.runtime_entries() |> stable_term(),
      context_runtime: Catalyst.Context.Registry.runtime_entries() |> stable_term(),
      hooks: hook_snapshot(),
      extension_processes: extension_process_snapshot(),
      sessions: registry_keys(Catalyst.Session.Registry),
      # PTY shell sessions (shell_session tool) — extension_processes only
      # watches the extensions registry, so a leaked shell needs its own
      # dimension. Async: reaping rides monitor DOWNs and registry cleanup.
      shell_sessions: registry_keys(Catalyst.Tools.Shell.Registry),
      app_env: app_env_snapshot(),
      system_prompt: Harness.file_snapshot(Catalyst.SystemPrompt.path()),
      prompt_files: source_manifest(Catalyst.SystemPrompt.prompts_dir()),
      agent_files: source_manifest(Catalyst.Tools.ListAgents.agents_dir()),
      boot_status: Extensions.boot_status(),
      boot_marker: Harness.file_snapshot(Catalyst.Extensions.BootGuard.marker_path()),
      ui: ui_snapshot(),
      shell_persistent_terms: persistent_snapshot()
    }
  end

  @doc "Poll known asynchronous teardown briefly, then fail with per-dimension diffs."
  @spec assert_clean!(t(), [atom()]) :: :ok
  def assert_clean!(baseline, exempt \\ []) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_assert_clean(baseline, MapSet.new(exempt), deadline)
  end

  @doc "Assert selected dimensions still equal a previously captured baseline."
  @spec assert_dimensions_unchanged!(t(), [atom()]) :: :ok
  def assert_dimensions_unchanged!(baseline, dimensions) do
    actual = capture()
    diffs = differences(baseline, actual, MapSet.new(Map.keys(baseline) -- dimensions))
    assert_no_diffs!(diffs)
  end

  @doc "Return normalized per-dimension differences for diagnostic assertions."
  @spec diff(t(), t(), [atom()]) :: map()
  def diff(expected, actual, exempt \\ []) do
    differences(expected, actual, MapSet.new(exempt))
  end

  defp do_assert_clean(baseline, exempt, deadline) do
    actual = capture()
    diffs = differences(baseline, actual, exempt)

    case map_size(diffs) do
      0 ->
        :ok

      _count ->
        case retryable?(diffs) and System.monotonic_time(:millisecond) < deadline do
          true ->
            receive do
            after
              10 -> do_assert_clean(baseline, exempt, deadline)
            end

          false ->
            assert_no_diffs!(diffs)
        end
    end
  end

  defp retryable?(diffs), do: Enum.all?(Map.keys(diffs), &(&1 in @async_dimensions))

  defp assert_no_diffs!(diffs) do
    case map_size(diffs) do
      0 ->
        :ok

      _count ->
        rendered =
          diffs
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join("\n", fn {dimension, %{expected: expected, actual: actual}} ->
            "  #{dimension}:\n    expected: #{inspect(expected, pretty: true, limit: :infinity)}\n" <>
              "    actual:   #{inspect(actual, pretty: true, limit: :infinity)}"
          end)

        flunk("flexibility runtime state leaked:\n#{rendered}")
    end
  end

  defp differences(expected, actual, exempt) do
    expected
    |> Enum.reject(fn {dimension, _value} -> MapSet.member?(exempt, dimension) end)
    |> Enum.reduce(%{}, fn {dimension, expected_value}, acc ->
      actual_value = Map.fetch!(actual, dimension)

      case actual_value == expected_value do
        true -> acc
        false -> Map.put(acc, dimension, %{expected: expected_value, actual: actual_value})
      end
    end)
  end

  defp tool_snapshot do
    runtime_names =
      for %{key: name, owner: owner} <- Runtime.list(:tool), owner != :host, do: name

    (Enum.map(Catalyst.Tools.Registry.default_tools(), & &1.name()) ++ runtime_names)
    |> Enum.uniq()
    |> Enum.sort()
    |> Map.new(fn name -> {name, Extensions.fetch(name)} end)
  end

  # The module dimension: extension-contributed code enters the VM without a
  # disk beam — in-memory (loaded file `[]`) from `Code.compile_*` or re-loaded
  # from its `*.ex` source path by the source-driven rebuild. A purge that
  # unregisters an owner but leaves its module loaded now shows up as a leak.
  # Disk-beam modules load lazily throughout a run and are deliberately excluded.
  defp module_snapshot do
    :code.all_loaded()
    |> Enum.filter(fn {module, file} ->
      source_loaded?(file) and not compiler_artifact?(module)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # Each Code.compile_* invocation leaves a transient `:elixir_compiler_N`
  # module behind; those are compiler plumbing, not extension contributions.
  defp compiler_artifact?(module) do
    module |> Atom.to_string() |> String.starts_with?("elixir_compiler_")
  end

  defp source_loaded?([]), do: true

  defp source_loaded?(file) when is_list(file),
    do: file |> List.to_string() |> String.ends_with?(".ex")

  defp source_loaded?(file) when is_binary(file), do: String.ends_with?(file, ".ex")
  defp source_loaded?(_preloaded_or_cover), do: false

  defp hook_snapshot do
    (Catalyst.Hooks.points() ++ [:event])
    |> Enum.uniq()
    |> Map.new(fn point ->
      handlers =
        point
        |> Catalyst.Hooks.handlers()
        |> Enum.map(&Map.delete(&1, :seq))
        |> stable_term()

      {point, handlers}
    end)
  end

  defp app_env_snapshot do
    Map.new(@app_env, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)
  end

  defp persistent_snapshot do
    Map.new(@persistent_keys, fn name ->
      key = {@shell_live, name}
      {name, Harness.persistent_snapshot(key) |> stable_term()}
    end)
  end

  defp ui_snapshot do
    case Process.whereis(@ui_registry) do
      pid when is_pid(pid) ->
        %{
          pages: apply(@ui_registry, :list_pages, []) |> without_sequence() |> stable_term(),
          renderers:
            apply(@ui_registry, :list_renderers, []) |> without_sequence() |> stable_term(),
          components:
            apply(@ui_registry, :list_components, []) |> without_sequence() |> stable_term(),
          commands: apply(@ui_registry, :list_commands, []) |> without_sequence() |> stable_term()
        }

      _not_started ->
        :not_loaded
    end
  end

  defp extension_process_snapshot do
    Catalyst.Extensions.ProcessRegistry
    |> registry_keys()
    |> Enum.map(fn owner -> {owner, length(Catalyst.Extensions.Processes.list(owner))} end)
    |> Enum.reject(fn {_owner, count} -> count == 0 end)
  end

  defp without_sequence(entries), do: Enum.map(entries, &Map.delete(&1, :seq))

  defp registry_keys(registry) do
    Registry.select(registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp source_manifest(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{Path.relative_to(&1, dir), &1})
    |> Enum.reject(fn {relative, _path} ->
      relative == ".git" or String.starts_with?(relative, ".git/")
    end)
    |> Enum.map(fn {relative, path} -> {relative, File.read!(path)} end)
    |> Enum.sort()
  end

  defp await_all_observers, do: Catalyst.Hooks.await_observers(:all, 5_000)

  defp stable_term(fun) when is_function(fun) do
    info = :erlang.fun_info(fun)

    {:function, Keyword.take(info, [:module, :name, :arity, :type, :index, :uniq]) |> Enum.sort()}
  end

  defp stable_term(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> stable_term()
    |> Map.put(:__struct__, struct.__struct__)
  end

  defp stable_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {stable_term(key), stable_term(value)} end)
    |> Map.new()
  end

  defp stable_term(list) when is_list(list), do: Enum.map(list, &stable_term/1)

  defp stable_term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&stable_term/1) |> List.to_tuple()

  defp stable_term(other), do: other
end
