defmodule Catalyst.Flex.Harness do
  @moduledoc """
  Shared setup, runtime-fixture, session, and lifecycle helpers for flexibility tests.

  Every helper that mutates global state registers its fallback cleanup before the
  mutation. Scenarios still perform an explicit revert; the callback is a second
  line of defence for assertion failures.
  """

  import ExUnit.Assertions

  alias Catalyst.Agent.Event
  alias Catalyst.Extensions
  alias Catalyst.Extensions.Installer
  alias Catalyst.Flex.Fixtures
  alias Catalyst.Session.{Manager, Server}

  @isolated_env [
    {:catalyst, :home, "home"},
    {:catalyst, :auth_path, "auth.json"},
    {:catalyst, :extensions_dir, "extensions"},
    {:catalyst, :sessions_root, "sessions"},
    {:catalyst, :system_prompt_path, "system_prompt.md"},
    {:catalyst, :prompts_dir, "prompts"},
    {:catalyst, :agents_dir, "agents"},
    {:catalyst, :boot_marker_path, "boot_marker"}
  ]

  @doc "Enter a unique Catalyst home and schedule exact environment restoration."
  @spec isolated_home!() :: Path.t()
  def isolated_home! do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_flex_#{System.pid()}_#{System.unique_integer([:positive, :monotonic])}"
      )

    previous = Map.new(@isolated_env, fn {app, key, _relative} -> {{app, key}, env(app, key)} end)
    File.mkdir_p!(root)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn {{app, key}, value} -> restore_app_env(app, key, value) end)
      File.mkdir_p!(Extensions.dir())
      _ = Extensions.load_all()
      File.rm_rf!(root)
    end)

    Enum.each(@isolated_env, fn {app, key, relative} ->
      Application.put_env(app, key, Path.join(root, relative))
    end)

    File.mkdir_p!(Application.fetch_env!(:catalyst, :home))
    File.mkdir_p!(Extensions.dir())
    File.mkdir_p!(Application.fetch_env!(:catalyst, :sessions_root))
    File.mkdir_p!(Application.fetch_env!(:catalyst, :prompts_dir))
    File.mkdir_p!(Application.fetch_env!(:catalyst, :agents_dir))

    case Extensions.load_all() do
      {:ok, %{failed: []}} ->
        await_extension_bootstrap!()
        Application.fetch_env!(:catalyst, :home)

      other ->
        flunk("could not enter isolated flexibility home: #{inspect(other)}")
    end
  end

  defp await_extension_bootstrap! do
    wait_until!(
      fn ->
        case :sys.get_state(Extensions) do
          %{bootstrap: :complete} -> true
          _in_progress -> false
        end
      end,
      5_000,
      "extension bootstrap did not complete"
    )

    wait_until!(
      fn -> not Catalyst.Extensions.BootGuard.crashed_last_boot?() end,
      5_000,
      "extension boot marker did not stabilize"
    )
  end

  @doc "Set one application environment value and schedule exact restoration."
  @spec with_app_env(atom(), atom(), term()) :: {:ok, term()} | :error
  def with_app_env(app, key, value) do
    previous = env(app, key)
    ExUnit.Callbacks.on_exit(fn -> restore_app_env(app, key, previous) end)
    put_app_env(app, key, value)
    previous
  end

  @doc "Set the application-wide loop module and schedule restoration."
  @spec with_agent_loop(module()) :: {:ok, term()} | :error
  def with_agent_loop(module), do: with_app_env(:catalyst, :agent_loop, module)

  @codex_api "openai-codex-responses"

  @doc "Override the stock Codex API in the live provider registry and schedule restoration."
  @spec with_codex_provider(module()) :: Catalyst.LLM.ProviderConfig.t()
  def with_codex_provider(module) do
    {:ok, previous} = Catalyst.LLM.Registry.fetch_config(@codex_api)
    ExUnit.Callbacks.on_exit(fn -> restore_codex_provider(previous) end)
    :ok = Catalyst.LLM.Registry.register_provider(@codex_api, module)
    previous
  end

  @doc "Restore a provider snapshot returned by `with_codex_provider/1`."
  @spec restore_codex_provider(Catalyst.LLM.ProviderConfig.t()) :: :ok
  def restore_codex_provider(config),
    do: Catalyst.LLM.Registry.register_provider(@codex_api, config)

  @doc "Override the Codex model catalog and default id, returning both prior values."
  @spec with_codex_models([map()], String.t()) :: map()
  def with_codex_models(models, default_id) do
    %{
      codex_models: with_app_env(:catalyst, :codex_models, models),
      codex_model: with_app_env(:catalyst, :codex_model, default_id)
    }
  end

  @doc "Restore an application environment snapshot returned by `with_app_env/3`."
  @spec restore_app_env(atom(), atom(), {:ok, term()} | :error) :: :ok
  def restore_app_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  def restore_app_env(app, key, :error), do: Application.delete_env(app, key)

  @doc "Write the live system-prompt override and schedule byte-exact restoration."
  @spec write_system_prompt!(String.t()) :: :absent | {:present, binary()}
  def write_system_prompt!(prompt) do
    path = Catalyst.SystemPrompt.path()
    previous = file_snapshot(path)
    ExUnit.Callbacks.on_exit(fn -> restore_file(path, previous) end)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, prompt)
    previous
  end

  @doc "Restore a file snapshot returned by `write_system_prompt!/1` or `file_snapshot/1`."
  @spec restore_file(Path.t(), :absent | {:present, binary()}) :: :ok
  def restore_file(path, :absent) do
    File.rm(path)
    :ok
  end

  def restore_file(path, {:present, bytes}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  @doc "Snapshot a file as exact bytes or absence."
  @spec file_snapshot(Path.t()) :: :absent | {:present, binary()}
  def file_snapshot(path) do
    case File.read(path) do
      {:ok, bytes} -> {:present, bytes}
      {:error, :enoent} -> :absent
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  @doc "Install a fixture through `Installer.install/3`; cleanup is registered first."
  @spec install_fixture!(String.t(), String.t()) :: map()
  def install_fixture!(fixture, owner) do
    owner = Extensions.sanitize_owner(owner)
    ExUnit.Callbacks.on_exit(fn -> remove_installed_fixture!(owner) end)

    case Installer.install(owner, Fixtures.extension_source!(fixture), "flex fixture") do
      {:ok, summary} ->
        Map.merge(summary, %{owner: owner, fixture: fixture})

      {:error, reason} ->
        flunk("fixture #{fixture} failed to install: #{Extensions.format_error(reason)}")
    end
  end

  @doc "Install a fixture under its own filename-derived owner."
  @spec install_fixture!(String.t()) :: map()
  def install_fixture!(fixture), do: install_fixture!(fixture, fixture)

  @doc "Explicitly remove an installed fixture's source, registrations, and modules."
  @spec remove_installed_fixture!(String.t()) :: :ok
  def remove_installed_fixture!(owner) do
    owner = Extensions.sanitize_owner(owner)
    path = Path.join(Extensions.dir(), owner <> ".ex")
    :ok = Extensions.uninstall(owner)
    File.rm(path)
    File.rm(path <> ".disabled")
    assert_clean_reload!()
  end

  @doc "Load an external source fixture through the production loader."
  @spec load_fixture!(String.t()) :: map()
  def load_fixture!(fixture) do
    path = Fixtures.extension_path(fixture)
    owner = path |> Path.basename(".ex") |> Extensions.sanitize_owner()
    ExUnit.Callbacks.on_exit(fn -> Extensions.uninstall(owner) end)

    case Extensions.load_file(path) do
      {:ok, summary} ->
        Map.merge(summary, %{owner: owner, path: path, fixture: fixture})

      {:error, reason} ->
        flunk("fixture #{fixture} failed to load: #{Extensions.format_error(reason)}")
    end
  end

  @doc "Explicitly purge an externally loaded fixture owner."
  @spec unload_fixture!(String.t()) :: :ok
  def unload_fixture!(owner), do: Extensions.uninstall(Extensions.sanitize_owner(owner))

  @doc "Drop raw extension source into the isolated directory without loading it."
  @spec write_extension!(String.t(), String.t()) :: Path.t()
  def write_extension!(name, source) do
    owner = Extensions.sanitize_owner(name)
    path = Path.join(Extensions.dir(), owner <> ".ex")
    ExUnit.Callbacks.on_exit(fn -> remove_extension!(owner) end)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end

  @doc "Remove a raw extension source and reconcile live owners."
  @spec remove_extension!(String.t()) :: :ok
  def remove_extension!(name) do
    owner = Extensions.sanitize_owner(name)
    path = Path.join(Extensions.dir(), owner <> ".ex")
    :ok = Extensions.uninstall(owner)
    File.rm(path)
    File.rm(path <> ".disabled")
    assert_clean_reload!()
  end

  @doc "Start a tracked session; it is always stopped during case cleanup."
  @spec start_session!(keyword()) :: %{id: String.t(), pid: pid()}
  def start_session!(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, Application.fetch_env!(:catalyst, :home))
    File.mkdir_p!(cwd)

    case Manager.start_session(Keyword.put_new(opts, :cwd, cwd)) do
      {:ok, session} ->
        ExUnit.Callbacks.on_exit(fn -> stop_session!(session.id, session.pid) end)
        session

      {:error, reason} ->
        flunk("could not start flexibility session: #{inspect(reason)}")
    end
  end

  @doc "Run one real, newly-created headless session through terminal `AgentEnd`."
  @spec run_headless_turn!(Server.input(), keyword()) :: map()
  def run_headless_turn!(prompt, opts \\ []) do
    session = start_session!(opts)

    try do
      run_session_turn!(session, prompt)
    after
      stop_session!(session.id, session.pid)
    end
  end

  @doc "Run one prompt on an existing tracked session and collect ordered events."
  @spec run_session_turn!(%{id: String.t(), pid: pid()}, Server.input()) :: map()
  def run_session_turn!(%{id: id, pid: pid}, prompt) do
    :ok = Phoenix.PubSub.subscribe(Catalyst.PubSub, Server.topic(id))
    :ok = Server.prompt(pid, prompt)
    events = collect_events!(id, 5_000)
    _ = :sys.get_state(pid)
    snapshot = Server.state(pid)
    Phoenix.PubSub.unsubscribe(Catalyst.PubSub, Server.topic(id))
    %{id: id, pid: pid, events: events, snapshot: snapshot}
  end

  @doc "Drive a loop module directly and return its result plus emitted events."
  @spec run_loop!(module(), [Catalyst.Message.t()] | Server.input(), map()) :: map()
  def run_loop!(loop, prompts, config) do
    prompts = normalize_prompts(prompts)
    {:ok, collector} = Agent.start_link(fn -> [] end)
    emit = fn event -> Agent.update(collector, &[event | &1]) end

    try do
      result = loop.run(prompts, %{system_prompt: nil, messages: []}, config, emit)
      %{result: result, events: collector |> Agent.get(& &1) |> Enum.reverse()}
    after
      Agent.stop(collector)
    end
  end

  @doc "Wait for all accepted observer work for a session key."
  @spec await_observers!(term()) :: :ok
  def await_observers!(session_key), do: Catalyst.Hooks.await_observers(session_key, 5_000)

  @doc "Stop a session and synchronously observe process termination."
  @spec stop_session!(String.t(), pid()) :: :ok
  def stop_session!(id, pid) do
    ref = Process.monitor(pid)
    result = Manager.stop(id)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        assert result == :ok
        :ok
    end
  end

  @doc "Wait until a named process is replaced, without sleeping."
  @spec wait_for_restart!(atom(), pid(), non_neg_integer()) :: pid()
  def wait_for_restart!(name, old_pid, timeout \\ 1_000) do
    wait_until!(
      fn ->
        case Process.whereis(name) do
          pid when is_pid(pid) and pid != old_pid -> {:ok, pid}
          _other -> false
        end
      end,
      timeout,
      "#{inspect(name)} did not restart"
    )
  end

  @doc "Bounded monotonic predicate retry for asynchronous registry teardown/restart."
  @spec wait_until!((-> false | true | {:ok, term()}), non_neg_integer(), String.t()) :: term()
  def wait_until!(predicate, timeout \\ 1_000, message \\ "condition did not become true") do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(predicate, deadline, message)
  end

  @doc "Snapshot a persistent-term key, preserving absence."
  @spec persistent_snapshot(term()) :: :absent | {:present, term()}
  def persistent_snapshot(key) do
    marker = make_ref()

    case :persistent_term.get(key, marker) do
      ^marker -> :absent
      value -> {:present, value}
    end
  end

  @doc "Restore a persistent-term snapshot."
  @spec restore_persistent(term(), :absent | {:present, term()}) :: :ok
  def restore_persistent(key, :absent), do: :persistent_term.erase(key)
  def restore_persistent(key, {:present, value}), do: :persistent_term.put(key, value)

  defp collect_events!(id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_events(id, deadline, [])
  end

  defp do_collect_events(id, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:agent_event, ^id, %Event.AgentEnd{} = event} -> Enum.reverse([event | acc])
      {:agent_event, ^id, event} -> do_collect_events(id, deadline, [event | acc])
    after
      remaining -> flunk("session #{id} did not emit terminal AgentEnd within the deadline")
    end
  end

  defp do_wait_until(predicate, deadline, message) do
    case predicate.() do
      true -> :ok
      {:ok, value} -> value
      false -> retry_wait(predicate, deadline, message)
      nil -> retry_wait(predicate, deadline, message)
    end
  end

  defp retry_wait(predicate, deadline, message) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case remaining > 0 do
      true ->
        receive do
        after
          min(10, remaining) -> do_wait_until(predicate, deadline, message)
        end

      false ->
        flunk(message)
    end
  end

  defp normalize_prompts(prompt) when is_binary(prompt), do: [Catalyst.Message.user(prompt)]
  defp normalize_prompts(%Catalyst.Message.User{} = prompt), do: [prompt]
  defp normalize_prompts(prompts) when is_list(prompts), do: prompts

  defp assert_clean_reload! do
    case Extensions.load_all() do
      {:ok, %{failed: []}} -> :ok
      other -> flunk("extension reconciliation failed: #{inspect(other)}")
    end
  end

  defp env(app, key), do: Application.fetch_env(app, key)

  defp put_app_env(app, key, :__delete__), do: Application.delete_env(app, key)
  defp put_app_env(app, key, value), do: Application.put_env(app, key, value)
end
