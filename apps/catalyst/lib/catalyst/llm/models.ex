defmodule Catalyst.LLM.Models do
  @moduledoc """
  Provider-neutral access to model catalogs registered in `Catalyst.LLM.Registry`.

  Catalog entries are annotated with their provider descriptor so callers can
  render and select models without importing concrete provider modules.
  """

  alias Catalyst.LLM.{ProviderConfig, Registry}
  alias Catalyst.Model

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
         true <- catalog_module?(catalog) or {:error, {:provider_has_no_catalog, provider_id}} do
      case catalog.model(model_id) do
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
         true <- catalog_module?(catalog) or {:error, {:provider_has_no_catalog, provider_id}} do
      case catalog.default_model_id() do
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

  defp aggregate(selected_api, model_id) do
    Registry.list()
    |> Enum.filter(fn {_api, config} -> catalog_module?(config.catalog) end)
    |> Enum.sort_by(fn {api, config} -> {config.catalog_priority, api} end)
    |> Enum.reduce_while({:ok, {[], nil}}, &read_catalog(&1, &2, selected_api, model_id))
    |> finish_aggregate(selected_api)
  end

  defp read_catalog({api, config}, {:ok, {groups, selected}}, selected_api, model_id) do
    id = selected_id(api, config.catalog, selected_api, model_id)

    case read_catalog_snapshot(config.catalog, id) do
      {:ok, snapshot} ->
        entries = Enum.map(snapshot.models, &annotate(&1, api, config))
        chosen = selected_entry(api, selected_api, snapshot.selected, config)
        {:cont, {:ok, {[entries | groups], chosen || selected}}}

      {:error, reason} ->
        {:halt, {:error, {api, reason}}}
    end
  end

  defp selected_id(api, _catalog, api, model_id), do: model_id
  defp selected_id(_api, catalog, _selected_api, _model_id), do: catalog.default_model_id()

  defp read_catalog_snapshot(catalog, id) do
    case catalog.catalog_snapshot(id) do
      %{models: models, selected: %{id: selected_id} = selected}
      when is_list(models) and is_binary(selected_id) ->
        case Enum.all?(models, &valid_entry?/1) do
          true -> {:ok, %{models: models, selected: selected}}
          false -> {:error, {:invalid_catalog_entries, catalog}}
        end

      other ->
        {:error, {:invalid_catalog_snapshot, catalog, other}}
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

  defp finish_aggregate({:error, _reason} = error, _selected_api), do: error

  defp finish_aggregate({:ok, {_groups, nil}}, selected_api) when is_binary(selected_api),
    do: {:error, {:catalog_not_found, selected_api}}

  defp finish_aggregate({:ok, {groups, selected}}, _selected_api),
    do: {:ok, %{models: groups |> Enum.reverse() |> List.flatten(), selected: selected}}
end
