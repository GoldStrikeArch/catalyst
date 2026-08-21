defmodule Catalyst.Runtime.ReadModel do
  @moduledoc """
  Host-extensible aggregation of specialized registry read models.

  Sources are stable `{module, function}` callbacks rather than captured
  functions, so hot-loaded code always invokes the current module generation.
  Each callback receives a `Catalyst.Runtime.Context` and returns
  `{:ok, %{claims: [...], contributions: [...]}}`.

  Source registration is process-free and read-mostly. Failures are isolated in
  the resulting graph's `source_status`; one unavailable host does not erase
  healthy core observations.
  """

  alias Catalyst.Tasks
  alias Catalyst.Runtime.{Claim, Context, Contribution, Graph, Snapshot}

  @sources_key {__MODULE__, :sources}
  @sources_lock {__MODULE__, :sources_lock}
  @default_source_timeout 11_000

  @type source_id :: atom()
  @type source :: {module(), atom()}
  @type source_result :: %{
          required(:claims) => [Claim.t()],
          required(:contributions) => [Contribution.t()],
          optional(:metadata) => map()
        }

  @doc "Register or replace a runtime read-model source."
  @spec register_source(source_id(), source()) :: :ok
  def register_source(id, {module, function})
      when is_atom(id) and is_atom(module) and is_atom(function) do
    update_sources(&Map.put(&1, id, {module, function}))
  end

  @doc "Remove one runtime read-model source."
  @spec unregister_source(source_id()) :: :ok
  def unregister_source(id) when is_atom(id) do
    update_sources(&Map.delete(&1, id))
  end

  @doc "Return registered source adapters in stable identifier order."
  @spec list_sources() :: [{source_id(), source()}]
  def list_sources, do: Enum.sort_by(sources(), &elem(&1, 0))

  @doc "Capture one aggregate graph without mutating any source registry."
  @spec snapshot(Context.t() | map() | keyword()) :: Graph.t()
  def snapshot(context \\ %{}) do
    context = Context.new(context)
    {claims, contributions, source_status, source_metadata} = collect(context)

    %Graph{
      snapshot_id: Snapshot.term_id({claims, contributions, source_status, source_metadata}),
      context: context,
      claims: claims,
      contributions: contributions,
      source_status: source_status,
      source_metadata: source_metadata,
      generated_at: DateTime.utc_now()
    }
  end

  defp collect(context) do
    list_sources()
    |> Enum.reduce(
      {[], [], %{}, %{}},
      fn {id, source}, {claims, contributions, statuses, metadata} ->
        case invoke_bounded(source, context) do
          {:ok, result} ->
            {
              result.claims ++ claims,
              result.contributions ++ contributions,
              Map.put(statuses, id, :ready),
              Map.put(metadata, id, Map.get(result, :metadata, %{}))
            }

          {:error, reason} ->
            {
              claims,
              contributions,
              Map.put(statuses, id, {:error, reason}),
              Map.put(metadata, id, %{})
            }
        end
      end
    )
    |> then(fn {claims, contributions, statuses, metadata} ->
      {
        Enum.sort_by(claims, &Claim.stable_key/1),
        Enum.sort_by(contributions, &Contribution.stable_key/1),
        statuses,
        metadata
      }
    end)
  end

  defp invoke_bounded(source, context) do
    task = Tasks.async(fn -> invoke(source, context) end)

    case Tasks.await(task, source_timeout()) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:source_task_exit, reason}}
      :timeout -> {:error, :source_timeout}
    end
  end

  defp invoke({module, function}, context) do
    case apply(module, function, [context]) do
      {:ok, %{claims: claims, contributions: contributions, metadata: metadata}}
      when is_list(claims) and is_list(contributions) and is_map(metadata) ->
        validate_result(claims, contributions, metadata)

      {:ok, %{claims: claims, contributions: contributions}}
      when is_list(claims) and is_list(contributions) ->
        validate_result(claims, contributions, %{})

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_source_result, other}}
    end
  rescue
    exception -> {:error, {:source_exception, exception}}
  catch
    kind, reason -> {:error, {:source_exit, kind, reason}}
  end

  defp validate_result(claims, contributions, metadata) do
    case Enum.all?(claims, &match?(%Claim{}, &1)) and
           Enum.all?(contributions, &match?(%Contribution{}, &1)) do
      true -> {:ok, %{claims: claims, contributions: contributions, metadata: metadata}}
      false -> {:error, :invalid_source_entries}
    end
  end

  defp update_sources(fun) do
    :global.trans(@sources_lock, fn ->
      :persistent_term.put(@sources_key, fun.(sources()))
    end)
  end

  defp source_timeout,
    do:
      Application.get_env(:catalyst, :runtime_read_model_source_timeout, @default_source_timeout)

  defp sources, do: :persistent_term.get(@sources_key, %{})
end
