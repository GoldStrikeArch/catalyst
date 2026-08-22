defmodule Catalyst.Pack.BootPlan do
  @moduledoc "Deterministic supervised children selected by compiled capability packs."

  alias Catalyst.Pack.Manifest
  alias Catalyst.Product.Composition

  @type entry :: %{id: term(), pack_id: String.t(), child_spec: Supervisor.child_spec()}

  @doc "Build pack-owned children in dependency and declaration order."
  @spec build(Composition.t() | [Manifest.t()]) :: {:ok, [entry()]} | {:error, term()}
  def build(%Composition{packs: packs}), do: build(packs)

  def build(manifests) when is_list(manifests) do
    with true <- Enum.all?(manifests, &match?(%Manifest{}, &1)),
         declarations = declarations(manifests),
         :ok <- reject_duplicate_ids(declarations) do
      build_entries(declarations)
    else
      false -> {:error, {:invalid_pack_boot_manifests, manifests}}
      {:error, _reason} = error -> error
    end
  end

  def build(manifests), do: {:error, {:invalid_pack_boot_manifests, manifests}}

  @doc "Return child specs for application startup, raising on invalid compiled data."
  @spec child_specs!(Composition.t()) :: [Supervisor.child_spec()]
  def child_specs!(%Composition{} = composition) do
    case build(composition) do
      {:ok, entries} -> Enum.map(entries, & &1.child_spec)
      {:error, reason} -> raise ArgumentError, "invalid pack boot plan: #{inspect(reason)}"
    end
  end

  defp declarations(manifests) do
    for manifest <- manifests,
        declaration <- manifest.processes,
        do: {manifest.id, declaration}
  end

  defp reject_duplicate_ids(declarations) do
    duplicates =
      declarations
      |> Enum.frequencies_by(fn {_pack_id, declaration} -> declaration.id end)
      |> Enum.flat_map(fn
        {id, count} when count > 1 -> [id]
        {_id, _count} -> []
      end)
      |> Enum.sort()

    case duplicates do
      [] -> :ok
      _duplicates -> {:error, {:duplicate_pack_process_ids, duplicates}}
    end
  end

  defp build_entries(declarations) do
    Enum.reduce_while(declarations, {:ok, []}, fn {pack_id, declaration}, {:ok, acc} ->
      case child_spec(declaration) do
        {:ok, child_spec} ->
          entry = %{id: declaration.id, pack_id: pack_id, child_spec: child_spec}
          {:cont, {:ok, [entry | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_pack_process, pack_id, declaration.id, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp child_spec(%{id: id, child_spec: module}) do
    {:ok, Supervisor.child_spec(module, id: id)}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
