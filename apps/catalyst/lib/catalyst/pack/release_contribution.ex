defmodule Catalyst.Pack.ReleaseContribution do
  @moduledoc "Validated declarative inputs consumed by the release builder."

  @type executable :: %{
          kind: :executable,
          id: String.t(),
          source: String.t(),
          target: String.t()
        }
  @type t :: executable()

  @doc "Validate and normalize release contributions from one pack manifest."
  @spec validate_all([map()]) :: {:ok, [t()]} | {:error, term()}
  def validate_all(contributions) when is_list(contributions) do
    with {:ok, normalized} <- validate_each(contributions),
         true <-
           unique?(normalized, :id) or
             {:error, {:duplicate_release_contribution_id, ids(normalized)}} do
      {:ok, normalized}
    end
  end

  def validate_all(contributions),
    do: {:error, {:invalid_release_contributions, contributions}}

  @doc "Validate one executable copied from the build host's PATH."
  @spec validate(map()) :: {:ok, t()} | {:error, term()}
  def validate(%{kind: :executable, id: id, source: source, target: target} = contribution)
      when map_size(contribution) == 4 do
    with true <- valid_id?(id),
         true <- executable_name?(source),
         true <- relative_target?(target) do
      {:ok, %{kind: :executable, id: id, source: source, target: target}}
    else
      false -> {:error, {:invalid_release_contribution, contribution}}
    end
  end

  def validate(contribution), do: {:error, {:invalid_release_contribution, contribution}}

  defp validate_each(contributions) do
    contributions
    |> Enum.reduce_while({:ok, []}, fn contribution, {:ok, acc} ->
      case validate(contribution) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp executable_name?(name) when is_binary(name) and byte_size(name) in 1..255 do
    not String.contains?(name, ["/", "\\", <<0>>]) and name not in [".", ".."]
  end

  defp executable_name?(_name), do: false

  defp valid_id?(id) when is_binary(id) do
    id != "" and byte_size(id) <= 128 and String.match?(id, ~r/\A[a-z0-9][a-z0-9._-]*\z/)
  end

  defp valid_id?(_id), do: false

  defp relative_target?(target) when is_binary(target) and byte_size(target) in 1..4_096 do
    segments = String.split(target, "/")

    Path.type(target) == :relative and not String.contains?(target, ["\\", <<0>>]) and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp relative_target?(_target), do: false

  defp unique?(contributions, field) do
    values = Enum.map(contributions, &Map.fetch!(&1, field))
    length(values) == MapSet.size(MapSet.new(values))
  end

  defp ids(contributions), do: Enum.map(contributions, & &1.id)
end
