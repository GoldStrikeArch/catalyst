defmodule CatalystCli do
  @moduledoc """
  A tiny headless entrypoint used to package Catalyst's core as a self-contained
  Burrito binary — and to prove the key claim: a packaged binary can still
  compile and load an extension at runtime (because the Elixir compiler ships in
  the release).

  `selftest` writes a uniquely named extension into an isolated temporary
  directory, loads and runs it under one reserved module name, then uninstalls
  it and removes only the scratch source it created. It never writes into the
  user's extension directory or creates a new module atom on each invocation.
  """

  @selftest_module Catalyst.Ext.CliSelftestProbe

  @doc """
  Run a CLI command. Returns `:ok` on success and `:error` on failure so the
  caller (`CatalystCli.Application.run_and_halt/0`) can set a meaningful process
  exit code for scripts/CI.
  """
  @spec run([String.t()]) :: :ok | :error
  def run(["tools" | _]) do
    case Catalyst.Extensions.await_ready() do
      :ok ->
        IO.puts("registered tools: " <> Enum.join(Enum.sort(Catalyst.Extensions.names()), ", "))
        :ok

      {:error, reason} ->
        command_failed(reason)
    end
  end

  def run(["selftest" | _]) do
    IO.puts("== Catalyst packaged self-develop test ==")

    case Catalyst.Extensions.await_ready() do
      :ok -> run_isolated_selftest()
      {:error, reason} -> selftest_failed({:extension_runtime_not_ready, reason})
    end
  end

  def run(argv) do
    IO.puts("usage: catalyst [tools|selftest] (got: #{inspect(argv)})")
    :error
  end

  # Exercise the just-loaded tool, guarding a missing registration or an
  # unexpected result shape so a broken hot-load reports failure instead of
  # crashing with a MatchError/UndefinedFunctionError.
  defp run_isolated_selftest do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    scratch_dir = Path.join(System.tmp_dir!(), "catalyst_cli_selftest_#{id}")
    io_device = Process.group_leader()
    live_paths = live_paths()

    case File.mkdir(scratch_dir) do
      :ok ->
        # The source may live outside the managed extension directory. Keep
        # every live Catalyst path untouched and serialize only the exact
        # compile/register/uninstall transaction.
        result =
          try do
            Catalyst.Extensions.locked(fn ->
              with_io_device(io_device, fn ->
                case prepare_selftest(scratch_dir, id, live_paths) do
                  {:ok, scratch} -> run_selftest(scratch)
                  {:error, reason} -> selftest_failed(reason)
                end
              end)
            end)
          rescue
            error -> selftest_failed({:exception, Exception.message(error)})
          catch
            kind, reason -> selftest_failed({kind, reason})
          end

        finish_scratch_cleanup(result, scratch_dir)

      {:error, reason} ->
        selftest_failed({:scratch_dir_create, scratch_dir, reason})
    end
  end

  defp prepare_selftest(scratch_dir, id, live_paths) do
    owner = "cli_selftest_#{id}"
    path = Path.join(scratch_dir, owner <> ".ex")

    scratch = %{
      path: path,
      owner: owner,
      tool: owner,
      module: @selftest_module,
      live_paths: live_paths
    }

    with :ok <- ensure_available(scratch),
         :ok <- create_scratch(scratch) do
      {:ok, scratch}
    end
  end

  defp with_io_device(io_device, fun) do
    previous = Process.group_leader()
    true = Process.group_leader(self(), io_device)

    try do
      fun.()
    after
      Process.group_leader(self(), previous)
    end
  end

  defp ensure_available(scratch) do
    cond do
      Catalyst.Extensions.fetch(scratch.tool) != :error ->
        {:error, {:tool_collision, scratch.tool}}

      Code.ensure_loaded?(scratch.module) ->
        {:error, {:module_collision, scratch.module}}

      Enum.any?(Catalyst.Extensions.list_loaded(), &(&1.owner == scratch.owner)) ->
        {:error, {:owner_collision, scratch.owner}}

      true ->
        :ok
    end
  end

  defp create_scratch(scratch) do
    case File.write(scratch.path, selftest_source(scratch), [:exclusive]) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(scratch.path)
        {:error, {:scratch_create, scratch.path, reason}}
    end
  end

  defp run_selftest(scratch) do
    result =
      try do
        case Catalyst.Extensions.load_file(scratch.path) do
          {:ok, summary} ->
            IO.puts("compiled + loaded at runtime: #{inspect(summary)}")
            run_loaded_tool(scratch)

          {:error, reason} ->
            selftest_failed(reason)
        end
      rescue
        error -> selftest_failed({:exception, Exception.message(error)})
      catch
        kind, reason -> selftest_failed({kind, reason})
      end

    case cleanup_selftest(scratch) do
      :ok when result == :ok ->
        IO.puts("OK: a self-contained binary loaded NEW code into the running VM.")
        :ok

      :ok ->
        result

      {:error, reason} ->
        selftest_failed({:cleanup_failed, reason})
    end
  end

  defp run_loaded_tool(scratch) do
    ctx = %{cwd: ".", call_id: "x", report: fn _ -> :ok end}

    with true <- live_paths() == scratch.live_paths,
         {:ok, tool} <- Catalyst.Extensions.fetch(scratch.tool),
         %{content: content} <- tool.execute(%{"text" => "packaged hot-load works"}, ctx),
         text when is_binary(text) <- Catalyst.Content.text_of(content) do
      IO.puts("called the new tool -> " <> text)
      :ok
    else
      other ->
        IO.puts("FAILED: tool loaded but did not run as expected (#{inspect(other)})")
        :error
    end
  end

  defp selftest_source(scratch) do
    """
    defmodule #{inspect(scratch.module)} do
      use Catalyst.Tools.Tool
      @impl true
      def name, do: #{inspect(scratch.tool)}
      @impl true
      def description, do: "Uppercases text."
      @impl true
      def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
      @impl true
      def execute(%{"text" => text}, _context), do: result(String.upcase(text))
    end
    """
  end

  defp selftest_failed(reason) do
    IO.puts("FAILED: #{inspect(reason)}")
    :error
  end

  defp command_failed(reason) do
    IO.puts(:stderr, "catalyst: extension runtime is not ready: #{inspect(reason)}")
    :error
  end

  defp live_paths do
    %{
      home: Path.expand(Catalyst.Paths.home()),
      extensions: Path.expand(Catalyst.Extensions.dir()),
      boot_marker: Path.expand(Catalyst.Extensions.BootGuard.marker_path())
    }
  end

  # Every identifier and path is generated by `prepare_selftest/0`, and the
  # source is created exclusively. Cleanup can therefore remove exactly this
  # run's contribution without touching a user-owned extension.
  defp cleanup_selftest(scratch) do
    errors =
      [cleanup_uninstall(scratch.owner), cleanup_source(scratch.path)]
      |> Enum.reject(&(&1 == :ok))

    case errors do
      [] ->
        IO.puts("cleaned up: removed the isolated selftest extension")
        :ok

      errors ->
        {:error, errors}
    end
  end

  defp cleanup_uninstall(owner) do
    case safe_uninstall(owner) do
      :ok -> :ok
      {:error, reason} -> {:uninstall, reason}
    end
  end

  defp cleanup_source(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:remove_source, path, reason}
    end
  end

  defp finish_scratch_cleanup(result, scratch_dir) do
    case File.rm_rf(scratch_dir) do
      {:ok, _removed} -> result
      {:error, path, reason} -> selftest_failed({:scratch_cleanup, path, reason})
    end
  end

  defp safe_uninstall(owner) do
    Catalyst.Extensions.uninstall(owner)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
