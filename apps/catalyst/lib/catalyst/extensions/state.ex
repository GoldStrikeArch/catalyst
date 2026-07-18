defmodule Catalyst.Extensions.State do
  @moduledoc """
  Typed runtime state for `Catalyst.Extensions`.

  The extension server owns orchestration; this struct makes its accepted-code,
  contribution, and setup-monitor invariants explicit without exposing them as
  part of the public extension API.
  """

  alias Catalyst.Extensions.ModuleVersions
  alias Catalyst.OwnedIndex

  @typedoc "A tool name and the module currently contributed under that name."
  @type tool_pair :: {String.t(), module()}

  @typedoc "A monitored extension setup and the ownership collisions it reported."
  @type setup_entry :: %{monitor: reference(), collisions: [term()]}

  @typedoc "Lifecycle state for the one host-controlled boot load."
  @type bootstrap :: :pending | :loading | :complete

  @type t :: %__MODULE__{
          contrib: %{optional(term()) => MapSet.t(tool_pair())},
          ownership: OwnedIndex.t(),
          modules: %{optional(term()) => [module()]},
          module_versions: ModuleVersions.t(),
          metadata: %{optional(term()) => map()},
          paths: %{optional(term()) => Path.t()},
          setup_collisions: %{optional(reference()) => setup_entry()},
          bootstrap: bootstrap(),
          boot_task: Task.t() | nil,
          hook_generation: reference() | nil,
          boot_status_revision: pos_integer() | nil,
          boot_token: String.t() | nil
        }

  defstruct contrib: %{},
            ownership: nil,
            modules: %{},
            module_versions: %{},
            metadata: %{},
            paths: %{},
            setup_collisions: %{},
            bootstrap: :pending,
            boot_task: nil,
            hook_generation: nil,
            boot_status_revision: nil,
            boot_token: nil

  @doc "Create an empty extension runtime state."
  @spec new() :: t()
  def new, do: %__MODULE__{ownership: OwnedIndex.new()}
end
