defmodule Catalyst.Extensions.State do
  @moduledoc """
  Typed runtime state and pure state transitions for `Catalyst.Extensions`.

  The extension server owns orchestration and side effects (ETS writes,
  registry purgers, module (un)loading); this module owns the tracking
  invariants: which owner contributed which tools/modules/metadata, the exact
  accepted BEAM binaries per module, and degraded owners whose last purge left
  residue. Every function here is a pure transition except
  `record_purge_result/3`, which also logs a retained-residue warning.
  """

  require Logger

  alias Catalyst.Extensions.Contribution

  @host_owner :host

  @typedoc "A tool name and the module currently contributed under that name."
  @type tool_pair :: {String.t(), module()}

  @typedoc "A monitored extension setup and the ownership collisions it reported."
  @type setup_entry :: %{monitor: reference(), collisions: [term()]}

  @typedoc "One retained module version: the owner that loaded it, its source path, and the exact BEAM."
  @type module_version :: %{owner: term(), path: Path.t(), beam: binary()}

  @typedoc "Bootstrap lifecycle: reseeding pending or acknowledged (hook readiness published)."
  @type bootstrap :: :pending | :complete

  @type t :: %__MODULE__{
          contrib: %{optional(term()) => MapSet.t(tool_pair())},
          owners: %{optional(String.t()) => term()},
          modules: %{optional(term()) => [module()]},
          module_versions: %{optional(module()) => [module_version()]},
          metadata: %{optional(term()) => map()},
          paths: %{optional(term()) => Path.t()},
          degraded: %{optional(term()) => [Catalyst.ExtensionAPI.purger_failure()]},
          setup_collisions: %{optional(reference()) => setup_entry()},
          hook_generation: reference() | nil,
          boot_token: String.t() | nil,
          bootstrap: bootstrap()
        }

  defstruct contrib: %{},
            owners: %{},
            modules: %{},
            module_versions: %{},
            metadata: %{},
            paths: %{},
            degraded: %{},
            setup_collisions: %{},
            hook_generation: nil,
            boot_token: nil,
            bootstrap: :pending

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
  claims, module list, retained BEAMs, metadata, and source path. Pure — the
  caller runs the registry/module side effects against the returned state.
  """
  @spec commit_contribution(t(), term(), Path.t(), Contribution.t()) :: t()
  def commit_contribution(%__MODULE__{} = state, owner, path, %Contribution{} = contribution) do
    pairs = Contribution.pairs(contribution)

    %{
      state
      | contrib: Map.put(state.contrib, owner, MapSet.new(pairs)),
        owners: replace_owner_claims(state.owners, owner, pairs),
        modules: Map.put(state.modules, owner, contribution.modules),
        module_versions:
          put_module_versions(state.module_versions, owner, path, contribution.beams),
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

  @doc "Drop every piece of `owner`'s tracking, installing the given post-purge module versions."
  @spec drop_owner(t(), term(), %{optional(module()) => [module_version()]}) :: t()
  def drop_owner(%__MODULE__{} = state, owner, module_versions) do
    %{
      state
      | contrib: Map.delete(state.contrib, owner),
        owners:
          Map.reject(state.owners, fn {_name, existing_owner} -> existing_owner == owner end),
        modules: Map.delete(state.modules, owner),
        module_versions: module_versions,
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

  # ---- module versions -------------------------------------------------------

  @doc "Replace `owner`'s retained BEAM versions with the given `module => beam` map."
  @spec put_module_versions(
          %{optional(module()) => [module_version()]},
          term(),
          Path.t(),
          %{module() => binary()}
        ) :: %{optional(module()) => [module_version()]}
  def put_module_versions(module_versions, owner, path, beams) do
    module_versions
    |> drop_owner_versions(owner)
    |> then(fn versions ->
      Enum.reduce(beams, versions, fn {module, beam}, acc ->
        version = %{owner: owner, path: path, beam: beam}
        Map.update(acc, module, [version], &[version | &1])
      end)
    end)
  end

  @doc "Remove every retained BEAM version owned by `owner`, dropping empty module entries."
  @spec drop_owner_versions(%{optional(module()) => [module_version()]}, term()) ::
          %{optional(module()) => [module_version()]}
  def drop_owner_versions(module_versions, owner) do
    Enum.reduce(module_versions, %{}, fn {module, versions}, acc ->
      case Enum.reject(versions, &(&1.owner == owner)) do
        [] -> acc
        remaining -> Map.put(acc, module, remaining)
      end
    end)
  end

  # ---- snapshots -------------------------------------------------------------

  @doc """
  Everything needed to reinstate `owner`'s currently accepted version after a
  rejected reload: exact beams, tool pairs, and metadata. `:none` (first
  install, or incomplete tracking) makes the later restore a no-op.
  """
  @spec owner_snapshot(t(), term()) :: {:ok, map()} | :none
  def owner_snapshot(%__MODULE__{} = state, owner) do
    with {:ok, path} <- Map.fetch(state.paths, owner),
         {:ok, modules} <- Map.fetch(state.modules, owner),
         {:ok, beams} <- owner_beams(modules, owner, state.module_versions) do
      pairs = state.contrib |> Map.get(owner, MapSet.new()) |> Enum.sort()

      {:ok,
       %{
         path: path,
         modules: modules,
         beams: beams,
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

  defp owner_beams(modules, owner, module_versions) do
    Enum.reduce_while(modules, {:ok, %{}}, fn module, {:ok, acc} ->
      case module_versions |> Map.get(module, []) |> Enum.find(&(&1.owner == owner)) do
        %{beam: beam} -> {:cont, {:ok, Map.put(acc, module, beam)}}
        nil -> {:halt, :error}
      end
    end)
  end
end
