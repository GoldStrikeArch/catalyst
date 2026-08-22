defmodule Catalyst.Pack.ProcessDeclaration do
  @moduledoc "Validated declaration for one compiled pack-owned OTP child."

  @type t :: %{id: term(), child_spec: module()}

  @doc "Validate process declarations without executing child-spec callbacks."
  @spec validate_all([map()]) :: {:ok, [t()]} | {:error, term()}
  def validate_all(declarations) when is_list(declarations) do
    with true <- Enum.all?(declarations, &valid?/1),
         true <- unique_ids?(declarations) do
      {:ok, declarations}
    else
      false -> {:error, {:invalid_pack_processes, declarations}}
    end
  end

  def validate_all(declarations), do: {:error, {:invalid_pack_processes, declarations}}

  defp valid?(%{id: id, child_spec: module} = declaration) when map_size(declaration) == 2,
    do: valid_id?(id) and module?(module)

  defp valid?(_declaration), do: false

  defp valid_id?(id) when is_binary(id), do: id != "" and byte_size(id) <= 128
  defp valid_id?(id), do: is_atom(id) and id not in [nil, true, false]

  defp module?(module) when is_atom(module),
    do: String.starts_with?(Atom.to_string(module), "Elixir.")

  defp module?(_module), do: false

  defp unique_ids?(declarations) do
    ids = Enum.map(declarations, & &1.id)
    length(ids) == MapSet.size(MapSet.new(ids))
  end
end
