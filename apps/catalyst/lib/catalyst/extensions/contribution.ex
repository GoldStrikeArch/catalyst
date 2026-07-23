defmodule Catalyst.Extensions.Contribution do
  @moduledoc """
  A compiled extension file's registry-neutral contribution.

  Produced by `Catalyst.Extensions.Loader.compile/1` and consumed by
  `Catalyst.Extensions` when committing a load: the modules the file defined
  (with their exact accepted BEAM binaries), the extension/tool classification,
  and the merged optional `metadata/0`.
  """

  @enforce_keys [:modules, :beams, :ext_mods, :tool_mods, :tool_names, :metadata]
  defstruct modules: [],
            beams: %{},
            ext_mods: [],
            tool_mods: [],
            tool_names: [],
            metadata: %{}

  @type t :: %__MODULE__{
          modules: [module()],
          beams: %{module() => binary()},
          ext_mods: [module()],
          tool_mods: [module()],
          tool_names: [String.t()],
          metadata: map()
        }

  @doc "Tool `{name, module}` pairs contributed by the file, in declaration order."
  @spec pairs(t()) :: [{String.t(), module()}]
  def pairs(%__MODULE__{tool_names: names, tool_mods: mods}), do: Enum.zip(names, mods)
end
