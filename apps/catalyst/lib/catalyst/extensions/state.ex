defmodule Catalyst.Extensions.State do
  @moduledoc """
  Typed runtime state and pure state transitions for `Catalyst.Extensions`.

  The extension server owns orchestration and side effects (ETS writes,
  registry purgers, module (un)loading); this module owns the tracking
  invariants: which owner contributed which tools/modules/metadata and degraded
  owners whose last purge left residue. Extension source is the durable
  definition; accepted BEAM version stacks are deliberately not retained.
  Every function here is a pure transition except
  `record_purge_result/3`, which also logs a retained-residue warning.
  """

  require Logger

  alias Catalyst.Extensions.Contribution

  @host_owner :host

  @typedoc "A tool name and the module currently contributed under that name."
  @type tool_pair :: {String.t(), module()}

  @typedoc "A monitored extension setup and the ownership collisions it reported."
  @type setup_entry :: %{monitor: reference(), collisions: [term()]}

  @typedoc "Bootstrap lifecycle: waiting for a host, running its workflow, or complete."
  @type bootstrap :: :waiting | :running | :complete

  @type t :: %__MODULE__{
          contrib: %{optional(term()) => MapSet.t(tool_pair())},
          owners: %{optional(String.t()) => term()},
          modules: %{optional(term()) => [module()]},
          beams: %{optional(term()) => %{optional(module()) => binary()}},
          extensions: %{optional(term()) => [module()]},
          metadata: %{optional(term()) => map()},
          paths: %{optional(term()) => Path.t()},
          degraded: %{optional(term()) => [Catalyst.ExtensionAPI.purger_failure()]},
          setup_collisions: %{optional(reference()) => setup_entry()},
          boot_token: String.t() | nil,
          bootstrap: bootstrap()
        }

  defstruct contrib: %{},
            owners: %{},
            modules: %{},
            beams: %{},
            extensions: %{},
            metadata: %{},
            paths: %{},
            degraded: %{},
            setup_collisions: %{},
            boot_token: nil,
            bootstrap: :waiting

  @doc "Create an empty extension runtime state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ---- tool ownership --------------------------------------------------------

  @doc "The owner currently holding tool `name`, or `nil` when unclaimed."
  @spec tool_owner(t(), String.t()) :: term() | nil
  def tool_owner(%__MODULE__{owners: owners}, name), do: Map.get(owners, name)

  @doc "Tool names in `names` already owned by a different owner, as `{name, existing_owner}`."
  @spec tool_owner_conflicts(t(), term(), [String.t()]) :: [{String.t(), term()}]
  def tool_owner_conflicts(%__MODULE__{} = state, owner, names) do
    Enum.flat_map(names, fn name ->
      case tool_owner(state, name) do
        nil -> []
        ^owner -> []
        other_owner -> [{name, other_owner}]
      end
    end)
  end

  @doc "Track one registered tool for `owner` (host tools claim the name but are not purge-tracked)."
  @spec track(t(), String.t(), module(), term()) :: t()
  def track(%__MODULE__{} = state, name, _module, @host_owner),
    do: put_in(state.owners[name], @host_owner)

  def track(%__MODULE__{} = state, name, module, owner) do
    pairs = Map.get(state.contrib, owner, MapSet.new())

    %{
      state
      | contrib: Map.put(state.contrib, owner, MapSet.put(pairs, {name, module})),
        owners: Map.put(state.owners, name, owner)
    }
  end

  # ---- committing a compiled contribution ------------------------------------

  @doc """
  Assemble the tracking for an accepted contribution: replace `owner`'s tool
  claims, module and extension lists, metadata, and source path. Pure — the
  caller runs registry and module side effects against the returned state.
  """
  @spec commit_contribution(t(), term(), Path.t(), Contribution.t()) :: t()
  def commit_contribution(%__MODULE__{} = state, owner, path, %Contribution{} = contribution) do
    pairs = Contribution.pairs(contribution)

    %{
      state
      | contrib: Map.put(state.contrib, owner, MapSet.new(pairs)),
        owners: replace_owner_claims(state.owners, owner, pairs),
        modules: Map.put(state.modules, owner, contribution.modules),
        beams: Map.put(state.beams, owner, contribution.beams),
        extensions: Map.put(state.extensions, owner, contribution.ext_mods),
        metadata: Map.put(state.metadata, owner, contribution.metadata),
        paths: Map.put(state.paths, owner, path)
    }
  end

  @doc "Replace every tool-name claim held by `owner` with the given `{name, module}` pairs."
  @spec replace_owner_claims(%{optional(String.t()) => term()}, term(), [tool_pair()]) ::
          %{optional(String.t()) => term()}
  def replace_owner_claims(owners, owner, pairs) do
    owners
    |> Map.reject(fn {_name, existing_owner} -> existing_owner == owner end)
    |> then(fn current -> Enum.reduce(pairs, current, &Map.put(&2, elem(&1, 0), owner)) end)
  end

  @doc """
  Cross-owner module collisions: other owners whose files also define modules
  in `modules`, as `{other_owner, overlapping_modules}`.
  """
  @spec module_conflicts(t(), term(), [module()]) :: [{term(), [module()]}]
  def module_conflicts(%__MODULE__{} = state, owner, modules) do
    mods = MapSet.new(modules)

    state.modules
    |> Map.delete(owner)
    |> Enum.flat_map(fn {other, other_mods} ->
      case Enum.filter(other_mods, &MapSet.member?(mods, &1)) do
        [] -> []
        overlap -> [{other, overlap}]
      end
    end)
  end

  # ---- purging ---------------------------------------------------------------

  @doc "Drop every piece of `owner`'s runtime tracking."
  @spec drop_owner(t(), term()) :: t()
  def drop_owner(%__MODULE__{} = state, owner) do
    %{
      state
      | contrib: Map.delete(state.contrib, owner),
        owners:
          Map.reject(state.owners, fn {_name, existing_owner} -> existing_owner == owner end),
        modules: Map.delete(state.modules, owner),
        beams: Map.delete(state.beams, owner),
        extensions: Map.delete(state.extensions, owner),
        metadata: Map.delete(state.metadata, owner),
        paths: Map.delete(state.paths, owner)
    }
  end

  @doc """
  Record the tagged outcome of a subsystem purge for `owner`.

  A failed purge must never be forgotten with live residue: the owner stays
  tracked as degraded (with the failure reasons) until a later purge or reload
  finishes cleanly, so cleanup remains retryable. Logs a warning on failure.
  """
  @spec record_purge_result(t(), term(), {:ok, term()} | {:error, term()}) :: t()
  def record_purge_result(%__MODULE__{} = state, owner, {:ok, _purged}),
    do: %{state | degraded: Map.delete(state.degraded, owner)}

  def record_purge_result(%__MODULE__{} = state, owner, {:error, failures}) do
    Logger.warning(
      "[extensions] purge of #{inspect(owner)} left residue; owner kept as degraded: " <>
        inspect(failures)
    )

    %{state | degraded: Map.put(state.degraded, owner, failures)}
  end

  # ---- snapshots -------------------------------------------------------------

  @doc """
  The active contribution data needed to reinstate `owner` after a rejected
  rebuild contribution. `:none` means the owner was not active.
  """
  @spec owner_snapshot(t(), term()) :: {:ok, map()} | :none
  def owner_snapshot(%__MODULE__{} = state, owner) do
    with {:ok, path} <- Map.fetch(state.paths, owner),
         {:ok, modules} <- Map.fetch(state.modules, owner) do
      pairs = state.contrib |> Map.get(owner, MapSet.new()) |> Enum.sort()

      {:ok,
       %{
         path: path,
         modules: modules,
         beams: Map.get(state.beams, owner, %{}),
         ext_mods: Map.get(state.extensions, owner, []),
         tool_names: Enum.map(pairs, &elem(&1, 0)),
         tool_mods: Enum.map(pairs, &elem(&1, 1)),
         metadata: Map.get(state.metadata, owner, %{})
       }}
    else
      _missing -> :none
    end
  end

  @doc "Every owner with live tracking: contributions, modules, or degraded residue."
  @spec tracked_owners(t()) :: MapSet.t(term())
  def tracked_owners(%__MODULE__{} = state) do
    state.contrib
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(MapSet.new(Map.keys(state.modules)))
    |> MapSet.union(MapSet.new(Map.keys(state.degraded)))
  end

  @doc "The `owner => modules` footprint of file-backed and degraded owners."
  @spec footprint(t()) :: %{optional(term()) => [module()]}
  def footprint(%__MODULE__{} = state) do
    state.degraded
    |> Map.keys()
    |> Map.new(&{&1, []})
    |> Map.merge(state.modules)
  end
end
