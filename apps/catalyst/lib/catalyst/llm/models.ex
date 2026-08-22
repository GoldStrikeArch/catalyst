defmodule Catalyst.LLM.Models do
  @moduledoc """
  Provider-neutral access to model catalogs registered in `Catalyst.LLM.Registry`.

  Catalog entries are annotated with their provider descriptor so callers can
  render and select models without importing concrete provider modules.
  """

  alias Catalyst.LLM.{ProviderConfig, Registry}
  alias Catalyst.{Model, Tasks}

  @default_catalog_timeout 1_000
  @selection_prefix "catalyst-provider-model:"

  @typedoc "Catalog metadata annotated with its registered provider."
  @type entry :: %{
          required(:id) => String.t(),
          required(:api) => String.t(),
          required(:provider) => String.t(),
          required(:provider_name) => String.t() | nil,
          required(:auth) => module() | nil,
          required(:controls) => map(),
          optional(atom()) => term()
        }

  @typedoc "The combined catalogs plus the selected provider entry."
  @type snapshot :: %{models: [entry()], selected: entry()}

  @doc "List models from every catalog-aware registered provider."
  @spec list() :: {:ok, [entry()]} | {:error, term()}
  def list do
    with {:ok, %{models: models}} <- aggregate(nil, nil) do
      {:ok, models}
    end
  end

  @doc "Read all catalogs and select `model_id` from `provider_id` consistently."
  @spec catalog_snapshot(String.t(), String.t()) :: {:ok, snapshot()} | {:error, term()}
  def catalog_snapshot(provider_id, model_id)
      when is_binary(provider_id) and is_binary(model_id) do
    with {:ok, {api, %ProviderConfig{catalog: catalog}}} <- Registry.fetch_by_id(provider_id),
         true <- catalog_module?(catalog) or {:error, {:provider_has_no_catalog, provider_id}} do
      aggregate(api, model_id)
    end
  end

  @doc "Build a request model using the selected provider's catalog."
  @spec build(String.t(), String.t()) :: {:ok, Model.t()} | {:error, term()}
  def build(provider_id, model_id) when is_binary(provider_id) and is_binary(model_id) do
    with {:ok, {_api, %ProviderConfig{catalog: catalog}}} <- Registry.fetch_by_id(provider_id),
         true <- catalog_module?(catalog) or {:error, {:provider_has_no_catalog, provider_id}},
         {:ok, result} <- catalog_call(provider_id, :model, fn -> catalog.model(model_id) end) do
      case result do
        %Model{} = model -> {:ok, model}
        other -> {:error, {:invalid_catalog_model, provider_id, other}}
      end
    end
  end

  @doc "Infer a model's provider descriptor and build the request model."
  @spec resolve(String.t()) :: {:ok, {String.t(), Model.t()}} | {:error, term()}
  def resolve(model_id) when is_binary(model_id) do
    with {:ok, provider_id} <- infer_provider(model_id),
         {:ok, model} <- build(provider_id, model_id) do
      {:ok, {provider_id, model}}
    end
  end

  @doc "Build a request model from an explicit provider and model id."
  @spec resolve(String.t(), String.t()) :: {:ok, {String.t(), Model.t()}} | {:error, term()}
  def resolve(provider_id, model_id)
      when is_binary(provider_id) and is_binary(model_id) do
    with {:ok, model} <- build(provider_id, model_id) do
      {:ok, {provider_id, model}}
    end
  end

  @doc "Return the selected provider's configured default model id."
  @spec default_model_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def default_model_id(provider_id) when is_binary(provider_id) do
    with {:ok, {_api, %ProviderConfig{catalog: catalog}}} <- Registry.fetch_by_id(provider_id),
         true <- catalog_module?(catalog) or {:error, {:provider_has_no_catalog, provider_id}},
         {:ok, result} <-
           catalog_call(provider_id, :default_model_id, fn -> catalog.default_model_id() end) do
      case result do
        id when is_binary(id) and id != "" -> {:ok, id}
        other -> {:error, {:invalid_default_model_id, provider_id, other}}
      end
    end
  end

  @doc "Resolve the registered provider descriptor id for a request model."
  @spec provider_id(Model.t()) :: {:ok, String.t()} | {:error, term()}
  def provider_id(%Model{api: api}) do
    case Registry.fetch_config(api) do
      {:ok, %ProviderConfig{id: id}} when is_binary(id) -> {:ok, id}
      {:ok, _legacy_config} -> {:error, {:provider_has_no_id, api}}
      :error -> {:error, {:unknown_api, api}}
    end
  end

  @doc "Find the sole provider advertising `model_id`."
  @spec infer_provider(String.t()) ::
          {:ok, String.t()}
          | {:error, {:unknown_model, String.t()} | {:ambiguous_model, String.t(), [String.t()]}}
  def infer_provider(model_id) when is_binary(model_id) do
    with {:ok, models} <- list() do
      providers =
        models
        |> Enum.filter(&(&1.id == model_id))
        |> Enum.map(& &1.provider)
        |> Enum.uniq()

      case providers do
        [provider] -> {:ok, provider}
        [] -> {:error, {:unknown_model, model_id}}
        many -> {:error, {:ambiguous_model, model_id, Enum.sort(many)}}
      end
    end
  end

  @doc "Build unambiguous select options while preserving plain values for unique model ids."
  @spec picker_options([entry()]) :: [{String.t(), String.t()}]
  def picker_options(models) when is_list(models) do
    counts = Enum.frequencies_by(models, & &1.id)

    Enum.map(models, fn entry ->
      case Map.fetch!(counts, entry.id) do
        1 ->
          {Map.get(entry, :name, entry.id), picker_value(models, entry.provider, entry.id)}

        _duplicate ->
          {qualified_name(entry), picker_value(models, entry.provider, entry.id)}
      end
    end)
  end

  @doc "Return the picker value for one provider/model pair."
  @spec picker_value([entry()], String.t(), String.t()) :: String.t()
  def picker_value(models, provider_id, model_id) do
    case Enum.count(models, &(&1.id == model_id)) do
      1 -> model_id
      _duplicate_or_missing -> encode_selection(provider_id, model_id)
    end
  end

  @doc "Decode a provider-qualified picker value or retain a legacy plain model id."
  @spec decode_selection(String.t()) ::
          {:ok, String.t() | %{required(String.t()) => String.t()}}
          | {:error, {:invalid_model_selection, term()}}
  def decode_selection(@selection_prefix <> encoded = selection) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, [provider_id, model_id]}
         when is_binary(provider_id) and provider_id != "" and is_binary(model_id) and
                model_id != "" <-
           Jason.decode(json) do
      {:ok, %{"provider_id" => provider_id, "model_id" => model_id}}
    else
      _invalid -> {:error, {:invalid_model_selection, selection}}
    end
  end

  def decode_selection(model_id) when is_binary(model_id) and model_id != "", do: {:ok, model_id}
  def decode_selection(selection), do: {:error, {:invalid_model_selection, selection}}

  defp aggregate(selected_api, model_id) do
    Registry.list()
    |> Enum.filter(fn {_api, config} -> catalog_module?(config.catalog) end)
    |> Enum.sort_by(fn {api, config} -> {config.catalog_priority, api} end)
    |> Enum.reduce({[], nil, []}, &read_catalog(&1, &2, selected_api, model_id))
    |> finish_aggregate(selected_api)
  end

  defp read_catalog({api, config}, {groups, selected, failures}, selected_api, model_id) do
    with {:ok, id} <- selected_id(api, config, selected_api, model_id),
         {:ok, snapshot} <- read_catalog_snapshot(config, id) do
      entries = Enum.map(snapshot.models, &annotate(&1, api, config))
      chosen = selected_entry(api, selected_api, snapshot.selected, config)
      {[entries | groups], chosen || selected, failures}
    else
      {:error, reason} ->
        failure = %{api: api, provider: config.id, reason: reason}
        {groups, selected, [failure | failures]}
    end
  end

  defp selected_id(api, _config, api, model_id), do: {:ok, model_id}

  defp selected_id(_api, config, _selected_api, _model_id) do
    with {:ok, id} <-
           catalog_call(config.id, :default_model_id, fn -> config.catalog.default_model_id() end),
         true <-
           (is_binary(id) and id != "") or {:error, {:invalid_default_model_id, config.id, id}} do
      {:ok, id}
    end
  end

  defp read_catalog_snapshot(config, id) do
    with {:ok, result} <-
           catalog_call(config.id, :catalog_snapshot, fn ->
             config.catalog.catalog_snapshot(id)
           end) do
      case result do
        %{models: models, selected: %{id: selected_id} = selected}
        when is_list(models) and is_binary(selected_id) ->
          case Enum.all?(models, &valid_entry?/1) and
                 Enum.any?(models, &(Map.get(&1, :id) == selected_id)) do
            true -> {:ok, %{models: models, selected: selected}}
            false -> {:error, {:invalid_catalog_entries, config.id}}
          end

        other ->
          {:error, {:invalid_catalog_snapshot, config.id, other}}
      end
    end
  end

  defp valid_entry?(%{id: id}) when is_binary(id), do: true
  defp valid_entry?(_entry), do: false

  defp catalog_module?(catalog), do: is_atom(catalog) and not is_nil(catalog)

  defp annotate(entry, api, config) do
    Map.merge(entry, %{
      api: api,
      provider: config.id,
      provider_name: config.name,
      auth: config.auth,
      controls: config.controls
    })
  end

  defp selected_entry(api, api, selected, config), do: annotate(selected, api, config)
  defp selected_entry(_api, _selected_api, _selected, _config), do: nil

  defp finish_aggregate({_groups, nil, failures}, selected_api) when is_binary(selected_api) do
    case Enum.find(failures, &(&1.api == selected_api)) do
      %{reason: reason} -> {:error, reason}
      nil -> {:error, {:catalog_not_found, selected_api}}
    end
  end

  defp finish_aggregate({[], nil, failures}, _selected_api),
    do: {:error, {:no_model_catalogs_available, Enum.reverse(failures)}}

  defp finish_aggregate({groups, selected, _failures}, _selected_api),
    do: {:ok, %{models: groups |> Enum.reverse() |> List.flatten(), selected: selected}}

  defp catalog_call(provider_id, callback, fun) do
    task = Tasks.async(fun)

    case Tasks.await(task, catalog_timeout()) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:model_catalog_exit, provider_id, callback, reason}}
      :timeout -> {:error, {:model_catalog_timeout, provider_id, callback}}
    end
  end

  defp catalog_timeout do
    case Application.get_env(:catalyst, :model_catalog_timeout, @default_catalog_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> @default_catalog_timeout
    end
  end

  defp qualified_name(entry),
    do: "#{Map.get(entry, :name, entry.id)} — #{entry.provider_name || entry.provider}"

  defp encode_selection(provider_id, model_id) do
    encoded = [provider_id, model_id] |> Jason.encode!() |> Base.url_encode64(padding: false)
    @selection_prefix <> encoded
  end
end
