defmodule CatalystWeb.ShellLive.Settings do
  @moduledoc """
  Loads, persists, and applies shell-level model and display preferences.

  Preferences intentionally use the historical `ShellLive` persistent-term keys
  so remounts and existing cleanup code keep the same behavior. Codex settings
  are applied to the current session for its next run; display settings never
  configure the session.
  """

  import Phoenix.Component, only: [assign: 2]

  require Logger

  alias Catalyst.LLM.Registry, as: LLMRegistry
  alias Catalyst.LLM.OpenAICodex.Controls, as: DefaultControls
  alias Catalyst.Session.Server
  alias CatalystWeb.UI.Registry, as: UIRegistry

  @codex_prefs_ptr {CatalystWeb.ShellLive, :codex_prefs}
  @ui_prefs_ptr {CatalystWeb.ShellLive, :ui_prefs}

  @type codex_prefs :: %{
          model: String.t(),
          provider: String.t(),
          effort: String.t(),
          fast: boolean(),
          transport: String.t()
        }
  @type ui_prefs :: %{quiet: boolean(), sidebar: boolean()}
  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Loads persisted Codex controls over the current application defaults."
  @spec load_codex() :: codex_prefs()
  def load_codex do
    defaults = %{
      model: DefaultControls.default_model_id(),
      provider: DefaultControls.id(),
      effort: DefaultControls.default_effort(),
      fast: false,
      transport: "auto"
    }

    case :persistent_term.get(@codex_prefs_ptr, nil) do
      %{} = saved -> Map.merge(defaults, saved)
      _not_saved -> defaults
    end
  end

  @doc "Loads persisted display preferences over their defaults."
  @spec load_ui() :: ui_prefs()
  def load_ui do
    defaults = %{quiet: false, sidebar: true}

    case :persistent_term.get(@ui_prefs_ptr, nil) do
      %{} = saved -> Map.merge(defaults, saved)
      _not_saved -> defaults
    end
  end

  @doc "Session run options for a new session, including registered UI controls."
  @spec start_opts(socket()) :: keyword()
  def start_opts(socket) do
    Keyword.merge(run_opts(socket.assigns.codex_prefs), UIRegistry.session_options())
  end

  @doc "Merges a Codex controls form submission and enforces model capabilities."
  @spec update_codex(codex_prefs(), map()) :: codex_prefs()
  def update_codex(prefs, params) do
    prefs
    |> put_if_present(:model, params["model"])
    |> infer_provider()
    |> put_if_present(:effort, params["effort"])
    |> put_if_present(:transport, params["transport"])
    |> clamp_effort()
    |> clamp_fast()
  end

  @doc "Toggles fast mode and clamps it off for models that do not support it."
  @spec toggle_fast(codex_prefs()) :: codex_prefs()
  def toggle_fast(prefs), do: prefs |> Map.update!(:fast, &(!&1)) |> clamp_fast()

  @doc "Persists and applies Codex controls to the attached session, when present."
  @spec apply_codex(socket(), codex_prefs()) :: socket()
  def apply_codex(socket, prefs) do
    persist(@codex_prefs_ptr, prefs)

    socket =
      assign(socket,
        codex_prefs: prefs,
        logged_in: Catalyst.Auth.logged_in?(auth_provider(prefs))
      )

    case socket.assigns.session_pid do
      pid when is_pid(pid) -> configure_session(socket, pid, prefs)
      _no_session -> socket
    end
  end

  @doc "Toggles and persists quiet mode without touching the agent session."
  @spec toggle_quiet(socket()) :: socket()
  def toggle_quiet(socket) do
    prefs = Map.update!(socket.assigns.ui_prefs, :quiet, &(!&1))
    persist(@ui_prefs_ptr, prefs)
    assign(socket, ui_prefs: prefs)
  end

  @doc "Toggles and persists sidebar visibility without touching the agent session."
  @spec toggle_sidebar(socket()) :: socket()
  def toggle_sidebar(socket) do
    prefs = Map.update(socket.assigns.ui_prefs, :sidebar, false, &(!&1))
    persist(@ui_prefs_ptr, prefs)
    assign(socket, ui_prefs: prefs)
  end

  @doc "One combined model-catalog snapshot with the selected entry."
  @spec catalog_snapshot(codex_prefs()) :: %{models: [map()], selected: map()}
  def catalog_snapshot(prefs) do
    models = Enum.flat_map(controls_modules(), &catalog_models/1)

    case Enum.find(models, &(&1.id == prefs.model)) do
      nil ->
        selected = unknown_entry(prefs)
        %{models: models ++ [selected], selected: selected}

      selected ->
        %{models: models, selected: selected}
    end
  end

  @doc """
  Builds the registry-resolved model used to start a session.

  Provider selection is deliberately left to the model API's live registry
  entry, so no provider is returned here.
  """
  @spec provider_config(codex_prefs()) :: Catalyst.Model.t()
  def provider_config(prefs) do
    controls = controls_for(provider_id(prefs))
    controls.model(prefs.model)
  end

  @doc "Converts the selected provider's controls into session run options."
  @spec run_opts(codex_prefs()) :: keyword()
  def run_opts(prefs) do
    controls = controls_for(provider_id(prefs))
    controls.run_opts(prefs)
  end

  @doc "Token-store provider for the selected model."
  @spec auth_provider(codex_prefs()) :: String.t()
  def auth_provider(prefs) do
    controls = controls_for(provider_id(prefs))
    controls.auth_provider()
  end

  @doc "Human-facing subscription name for the selected model."
  @spec auth_label(codex_prefs()) :: String.t()
  def auth_label(prefs) do
    controls = controls_for(provider_id(prefs))
    controls.auth_label()
  end

  @doc "Interactive login function owned by the selected provider controls."
  @spec login_fun(codex_prefs()) :: (-> {:ok, String.t() | nil} | {:error, term()})
  def login_fun(prefs) do
    controls = controls_for(provider_id(prefs))
    Function.capture(controls, :login, 0)
  end

  @doc "Synchronizes provider controls from the attached session source of truth."
  @spec sync_from_session(socket()) :: socket()
  def sync_from_session(socket) do
    model = socket.assigns.session_model || provider_config(socket.assigns.codex_prefs)
    opts = socket.assigns.session_opts || []
    provider = provider_from_model(model)

    prefs =
      clamp_fast(%{
        model: model.id,
        provider: provider,
        effort: opts[:reasoning_effort] || default_effort(provider),
        fast: opts[:service_tier] == "priority",
        transport: to_string(opts[:transport] || "auto")
      })

    persist(@codex_prefs_ptr, prefs)

    socket
    |> assign(
      codex_prefs: prefs,
      logged_in: Catalyst.Auth.logged_in?(auth_provider(prefs))
    )
  end

  defp configure_session(socket, pid, prefs) do
    model = provider_config(prefs)
    opts = run_opts(prefs)

    try do
      :ok = Server.configure(pid, model: model, opts: opts)
      # Merge rather than replace: the server merges too, so a capability grant
      # set by another control must not disappear from the UI's own view.
      assign(socket,
        session_model: model,
        session_opts: merge_local_opts(socket.assigns.session_opts || [], opts)
      )
    catch
      # The session can die during a control change. The monitor callback will
      # reattach, while the persisted preferences apply to the next session.
      :exit, _reason -> socket
    end
  end

  defp merge_local_opts(opts, changes) do
    Enum.reduce(changes, opts, fn
      {key, nil}, acc -> Keyword.delete(acc, key)
      {key, value}, acc -> Keyword.put(acc, key, value)
    end)
  end

  defp put_if_present(prefs, _key, nil), do: prefs
  defp put_if_present(prefs, key, value), do: Map.put(prefs, key, value)

  defp clamp_fast(prefs) do
    case catalog_snapshot(prefs).selected.fast? do
      true -> prefs
      false -> %{prefs | fast: false}
    end
  end

  defp clamp_effort(prefs) do
    selected = catalog_snapshot(prefs).selected

    case prefs.effort in selected.efforts do
      true -> prefs
      false -> %{prefs | effort: selected.default_effort}
    end
  end

  defp infer_provider(prefs) do
    case Enum.find(catalog_snapshot(prefs).models, &(&1.id == prefs.model)) do
      %{provider: provider} -> Map.put(prefs, :provider, provider)
      nil -> Map.put(prefs, :provider, DefaultControls.id())
    end
  end

  defp provider_from_model(%{provider: provider}) when is_binary(provider) do
    controls_for(provider).id()
  end

  defp provider_from_model(_model), do: DefaultControls.id()

  defp default_effort(provider) do
    controls = controls_for(provider)
    controls.default_effort()
  end

  defp unknown_entry(%{model: model} = prefs) do
    controls = controls_for(provider_id(prefs))
    decorate_catalog_entry(controls.catalog_entry(model), controls)
  end

  defp catalog_models(controls) do
    Enum.map(controls.list_models(), &decorate_catalog_entry(&1, controls))
  rescue
    exception ->
      Logger.warning(
        "[settings] provider controls #{inspect(controls)} catalog failed: " <>
          Exception.message(exception)
      )

      []
  catch
    kind, reason ->
      Logger.warning(
        "[settings] provider controls #{inspect(controls)} catalog failed: " <>
          Exception.format_banner(kind, reason)
      )

      []
  end

  defp decorate_catalog_entry(entry, controls) do
    Map.merge(entry, %{provider: controls.id(), auth_label: controls.auth_label()})
  end

  defp controls_for(provider) do
    Enum.find(controls_modules(), DefaultControls, &(&1.id() == provider))
  end

  defp provider_id(prefs), do: Map.get(prefs, :provider, DefaultControls.id())

  defp controls_modules do
    optional =
      LLMRegistry.list()
      |> Map.values()
      |> Enum.map(& &1.controls)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> List.delete(DefaultControls)

    [DefaultControls | optional]
  end

  defp persist(key, prefs), do: :persistent_term.put(key, prefs)
end
