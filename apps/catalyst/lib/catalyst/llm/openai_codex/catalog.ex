defmodule Catalyst.LLM.OpenAICodex.Catalog do
  @moduledoc """
  Pure transformations for the OpenAI Codex model catalog.

  This module owns the bundled fallback entries and converts both configured
  entries and the live `/codex/models` payload into the shape consumed by the
  UI. Fetching and cache freshness are owned by `CatalogCache`.
  """

  @efforts ~w(low medium high xhigh)
  @default_effort "medium"

  # Mirrors codex-rs/models-manager/models.json (visibility: list) as of
  # 2026-06: slug, display name, priority-tier ("Fast") support. All share a
  # 272k context window and low/medium/high/xhigh efforts (default medium).
  @models [
    %{id: "gpt-5.5", name: "GPT-5.5", fast?: true},
    %{id: "gpt-5.4", name: "GPT-5.4", fast?: true},
    %{id: "gpt-5.4-mini", name: "GPT-5.4 mini", fast?: false},
    %{id: "gpt-5.3-codex", name: "GPT-5.3 Codex", fast?: false},
    %{id: "gpt-5.2", name: "GPT-5.2", fast?: false}
  ]

  @typedoc "One normalized catalog entry (UI metadata, not a request model)."
  @type entry :: %{
          id: String.t(),
          name: String.t(),
          fast?: boolean(),
          efforts: [String.t()],
          default_effort: String.t()
        }

  @doc "Return the normalized bundled fallback catalog."
  @spec built_in() :: [entry()]
  def built_in, do: Enum.map(@models, &normalize/1)

  @doc "Normalize a configured or bare catalog entry."
  @spec normalize(map()) :: entry()
  def normalize(entry) do
    id = Map.fetch!(entry, :id)

    %{
      id: id,
      name: Map.get(entry, :name, id),
      fast?: Map.get(entry, :fast?, false),
      efforts: Map.get(entry, :efforts, @efforts),
      default_effort: Map.get(entry, :default_effort, @default_effort)
    }
  end

  @doc """
  Parse live payload entries, retaining list-visible models in priority order.

  Fast support comes from either the `priority` service tier or the legacy
  `fast` additional-speed tier. Missing reasoning levels use the bundled
  effort list.
  """
  @spec parse_live_models([map()]) :: [entry()]
  def parse_live_models(models) when is_list(models) do
    models
    |> Enum.filter(&list_visible?/1)
    |> Enum.sort_by(&priority/1)
    |> Enum.map(&live_entry/1)
    |> Enum.filter(&is_binary(&1.id))
  end

  @doc "Supported reasoning efforts used when a catalog entry omits them."
  @spec efforts() :: [String.t()]
  def efforts, do: @efforts

  @doc "The reasoning effort used when a catalog entry omits its default."
  @spec default_effort() :: String.t()
  def default_effort, do: @default_effort

  defp list_visible?(%{"visibility" => "list"}), do: true
  defp list_visible?(_entry), do: false

  defp priority(entry), do: entry["priority"] || 0

  defp live_entry(entry) do
    %{
      id: entry["slug"],
      name: entry["display_name"] || entry["slug"],
      fast?: live_fast?(entry),
      efforts: live_efforts(entry),
      default_effort: entry["default_reasoning_level"] || @default_effort
    }
  end

  defp live_fast?(entry) do
    Enum.any?(entry["service_tiers"] || [], &(&1["id"] == "priority")) or
      "fast" in (entry["additional_speed_tiers"] || [])
  end

  defp live_efforts(%{"supported_reasoning_levels" => levels})
       when is_list(levels) and levels != [] do
    levels
    |> Enum.map(& &1["effort"])
    |> Enum.filter(&is_binary/1)
  end

  defp live_efforts(_entry), do: @efforts
end
