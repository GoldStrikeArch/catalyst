defmodule Catalyst.Extensions.CompilerTracer do
  @moduledoc """
  Records modules actually emitted while compiling one extension file.

  The compiler callback sends tiny, reference-tagged messages to the process
  awaiting the isolated compile task. This lets cleanup remain exact even when
  source uses a dynamic `defmodule` name, the compile raises after emitting an
  earlier module, or the compile task is killed by its deadline.
  """

  @collector_key {__MODULE__, :collector}
  @message_tag :catalyst_extension_compiled_module

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
  def collect(ref), do: ref |> collect([]) |> Enum.reverse() |> Enum.uniq()

  @doc false
  @spec trace(term(), Macro.Env.t()) :: :ok
  def trace({:on_module, _bytecode, _metadata}, %{module: module}) when is_atom(module) do
    case Process.get(@collector_key) do
      {collector, ref} -> send(collector, {@message_tag, ref, module})
      nil -> :ok
    end

    :ok
  end

  def trace(_event, _env), do: :ok

  defp collect(ref, modules) do
    receive do
      {@message_tag, ^ref, module} -> collect(ref, [module | modules])
    after
      0 -> modules
    end
  end
end
