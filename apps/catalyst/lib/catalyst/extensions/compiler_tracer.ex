defmodule Catalyst.Extensions.CompilerTracer do
  @moduledoc """
  Records modules actually emitted while compiling one extension file.

  The compiler callback sends tiny, reference-tagged messages to the process
  awaiting the isolated compile task. This lets cleanup remain exact even when
  source uses a dynamic `defmodule` name, the compile raises after emitting an
  earlier module, or the compile task is killed by its deadline.

  Provisional compiler ownership and emitted modules are also journaled in
  `:persistent_term`. The journal outlives the `Catalyst.Extensions` process
  and can be consumed through `drain_provisional/0`. Replacement does not
  currently drain it automatically; wiring that recovery path, and replacing
  the write-heavy persistent-term store, are deferred until an orphan-compiler
  reproduction and benchmark justify the global-GC tradeoff.
  """

  @collector_key {__MODULE__, :collector}
  @message_tag :catalyst_extension_compiled_module
  @journal_key {__MODULE__, :provisional}
  @journal_lock {__MODULE__, :provisional_lock}
  @compiler_stop_timeout 5_000

  @type provisional_entry :: %{pid: pid(), modules: [module()]}

  @doc false
  @spec reserve(reference(), pid()) :: :ok
  def reserve(ref, pid) when is_reference(ref) and is_pid(pid) do
    update_journal(fn journal ->
      Map.put(journal, ref, %{pid: pid, modules: []})
    end)
  end

  @doc false
  @spec start(pid(), reference()) :: :ok
  def start(collector, ref) when is_pid(collector) and is_reference(ref) do
    Process.put(@collector_key, {collector, ref})
    :ok
  end

  @doc false
  @spec stop() :: :ok
  def stop do
    Process.delete(@collector_key)
    :ok
  end

  @doc false
  @spec collect(reference()) :: [module()]
  def collect(ref) do
    messages = ref |> collect_messages([]) |> Enum.reverse()
    Enum.uniq(provisional_modules(ref) ++ messages)
  end

  @doc false
  @spec acknowledge(reference()) :: :ok
  def acknowledge(ref) when is_reference(ref) do
    update_journal(&Map.delete(&1, ref))
  end

  @doc false
  @spec drain_provisional() :: [module()]
  def drain_provisional do
    provisional_entries()
    |> stop_compilers()

    take_provisional_modules()
  end

  @doc false
  @spec provisional?() :: boolean()
  def provisional?, do: map_size(provisional_entries()) > 0

  @doc false
  @spec trace(term(), Macro.Env.t()) :: :ok
  def trace({:on_module, _bytecode, _metadata}, %{module: module}) when is_atom(module) do
    case Process.get(@collector_key) do
      {collector, ref} ->
        :ok = record_module(ref, module)
        send(collector, {@message_tag, ref, module})

      nil ->
        :ok
    end

    :ok
  end

  def trace(_event, _env), do: :ok

  defp collect_messages(ref, modules) do
    receive do
      {@message_tag, ^ref, module} -> collect_messages(ref, [module | modules])
    after
      0 -> modules
    end
  end

  defp record_module(ref, module) do
    update_journal(fn journal ->
      entry = Map.get(journal, ref, %{pid: self(), modules: []})
      Map.put(journal, ref, %{entry | modules: [module | entry.modules]})
    end)
  end

  defp provisional_modules(ref) do
    @journal_key
    |> :persistent_term.get(%{})
    |> Map.get(ref, %{modules: []})
    |> Map.fetch!(:modules)
    |> Enum.reverse()
  end

  defp provisional_entries do
    case :persistent_term.get(@journal_key, %{}) do
      journal when is_map(journal) -> journal
      _invalid -> %{}
    end
  end

  defp stop_compilers(entries) do
    entries
    |> Enum.map(fn {_ref, %{pid: pid}} -> {pid, Process.monitor(pid)} end)
    |> Enum.each(fn {pid, monitor} ->
      Process.exit(pid, :kill)
      await_compiler_down(pid, monitor)
    end)
  end

  defp await_compiler_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @compiler_stop_timeout -> exit({:stale_extension_compiler_timeout, pid})
    end
  end

  defp take_provisional_modules do
    journal = swap_journal(%{})

    journal
    |> Map.values()
    |> Enum.flat_map(& &1.modules)
    |> Enum.uniq()
  end

  defp update_journal(fun) do
    journal =
      with_journal_lock(fn ->
        current = provisional_entries()
        updated = fun.(current)
        :persistent_term.put(@journal_key, updated)
        updated
      end)

    case is_map(journal) do
      true -> :ok
      false -> exit(:provisional_journal_unavailable)
    end
  end

  defp swap_journal(replacement) do
    with_journal_lock(fn ->
      current = provisional_entries()
      :persistent_term.put(@journal_key, replacement)
      current
    end)
  end

  defp with_journal_lock(fun) do
    :global.trans({@journal_lock, self()}, fun, [node()], :infinity)
  end
end
