defmodule Catalyst.Extensions.ModuleScan do
  @moduledoc """
  Finds statically named modules in extension source without compiling it.

  Nested aliases are expanded the same way as `defmodule`; dynamic names are
  deliberately ignored because guessing them could purge an unrelated module
  after a partial compile failure.

  ## Examples

      iex> source = \"""
      ...> defmodule Example.Outer do
      ...>   defmodule Inner do
      ...>   end
      ...> end
      ...> \"""
      iex> Catalyst.Extensions.ModuleScan.modules(source)
      [Example.Outer, Example.Outer.Inner]

      iex> Catalyst.Extensions.ModuleScan.modules("defmodule :raw_extension_module do end")
      [:raw_extension_module]
  """

  @doc """
  Return the statically resolvable `defmodule` names in source order.

  Invalid source returns an empty list. Module names built dynamically from
  attributes, interpolation, or other expressions are skipped.
  """
  @spec modules(String.t()) :: [module()]
  def modules(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> ast |> collect([], []) |> Enum.reverse() |> Enum.uniq()
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  end

  defp collect({:defmodule, _, [name | rest]}, prefix, acc) do
    case static_module_name(name, prefix) do
      {:ok, module, child_prefix} ->
        Enum.reduce(rest, [module | acc], &collect(&1, child_prefix, &2))

      :error ->
        Enum.reduce(rest, acc, &collect(&1, prefix, &2))
    end
  end

  defp collect({form, _meta, args}, prefix, acc) when is_list(args) do
    acc = collect(form, prefix, acc)
    Enum.reduce(args, acc, &collect(&1, prefix, &2))
  end

  defp collect({left, right}, prefix, acc),
    do: collect(right, prefix, collect(left, prefix, acc))

  defp collect(list, prefix, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect(&1, prefix, &2))

  defp collect(_other, _prefix, acc), do: acc

  defp static_module_name({:__aliases__, _, segments}, prefix) do
    cond do
      segments == [] or not Enum.all?(segments, &is_atom/1) ->
        :error

      prefix == [] or hd(segments) == :"Elixir" ->
        {:ok, Module.concat(segments), segments}

      true ->
        {:ok, Module.concat(prefix ++ segments), prefix ++ segments}
    end
  end

  defp static_module_name(name, _prefix) when is_atom(name), do: {:ok, name, [name]}
  defp static_module_name(_name, _prefix), do: :error
end
