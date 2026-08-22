defmodule CatalystWeb.ShellLive.Settings do
  @moduledoc """
  Loads, persists, and applies shell-level model and display preferences.

  Preferences intentionally use the historical `ShellLive` persistent-term keys
  so remounts and existing cleanup code keep the same behavior. Codex settings
  are applied to the current session for its next run; display settings never
  configure the session.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Catalyst.LLM.Models
  alias Catalyst.Session.Server
  alias Catalyst.Workflow.Registry, as: WorkflowRegistry
  alias CatalystWeb.ShellLive.SessionLifecycle

  @codex_prefs_ptr {CatalystWeb.ShellLive, :codex_prefs}
  @ui_prefs_ptr {CatalystWeb.ShellLive, :ui_prefs}
  # Machine-capability grants get their own key on purpose: `sync_from_session`
  # rebuilds `codex_prefs` wholesale from the session's Codex options and would
  # drop anything else stored there, and `ui_prefs` is display-only state that
  # never configures the session.
  @machine_prefs_ptr {CatalystWeb.ShellLive, :machine_prefs}
  # Workflow selection is provider-agnostic, so it also gets its own key
  # rather than riding in `codex_prefs` (same wholesale-rebuild hazard).
  @workflow_prefs_ptr {CatalystWeb.ShellLive, :workflow_prefs}
  @type codex_prefs :: %{
          model: String.t(),
          provider: String.t(),
          effort: String.t(),
          fast: boolean(),
          transport: String.t()
        }
  @type ui_prefs :: %{quiet: boolean(), sidebar: boolean()}
  @type machine_prefs :: %{computer_use: boolean()}
  @type workflow_prefs :: %{workflow: String.t() | nil}
  @type workflow_option :: %{
          name: Catalyst.Workflow.Registry.name(),
          module: module() | nil,
          source: Catalyst.Workflow.Registry.source() | :unavailable
        }
  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Loads persisted Codex controls over the current application defaults."
  @spec load_codex() :: codex_prefs()
  def load_codex do
    %{provider_id: provider, model_id: model} = default_selection()

    defaults = %{
      model: model,
      provider: provider,
      effort: selected_entry(provider, model).default_effort,
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

  @doc "Loads the persisted workflow selection (nil selects the default chain)."
  @spec load_workflow() :: workflow_prefs()
  def load_workflow do
    defaults = %{workflow: nil}

    case :persistent_term.get(@workflow_prefs_ptr, nil) do
      %{} = saved -> Map.merge(defaults, saved)
      _not_saved -> defaults
    end
  end

  @doc "Loads persisted machine-capability grants over their defaults (all off)."
  @spec load_machine() :: machine_prefs()
  def load_machine do
    defaults = %{computer_use: false}

    case :persistent_term.get(@machine_prefs_ptr, nil) do
      %{} = saved -> Map.merge(defaults, saved)
      _not_saved -> defaults
    end
  end

  @doc """
  Toggles computer use, persists it, and applies it to the attached session.

  Like the Codex controls this takes effect on the session's NEXT run; the
  transcript and the running session are untouched. The grant is still subject
  to backend availability — `Catalyst.Tools.Computer.Availability` decides
  whether the tools can be advertised at all.
  """
  @spec toggle_computer_use(socket()) :: socket()
  def toggle_computer_use(socket) do
    prefs = Map.update!(socket.assigns.machine_prefs, :computer_use, &(!&1))
    persist(@machine_prefs_ptr, prefs)
    socket = assign(socket, machine_prefs: prefs)

    case socket.assigns.session_pid do
      pid when is_pid(pid) -> configure_machine(socket, pid, prefs)
      _no_session -> socket
    end
  end

  @doc "Converts machine-capability grants into session run options."
  @spec machine_opts(machine_prefs()) :: keyword()
  def machine_opts(prefs), do: [computer_use: prefs.computer_use]

  @doc """
  Converts the workflow selection into session start options.

  A saved name whose workflow no longer resolves (its extension was purged or
  the VM restarted without it) is dropped rather than passed on: an unknown
  explicit name fails every run, so a stale preference must not poison a fresh
  session. `sync_workflow_from_opts/2` then self-heals the preference from
  what the session actually got.
  """
  @spec workflow_opts(workflow_prefs()) :: keyword()
  def workflow_opts(%{workflow: nil}), do: []

  def workflow_opts(%{workflow: name}) do
    case WorkflowRegistry.fetch(name) do
      {:ok, _module} -> [workflow: name]
      {:error, _reason} -> []
    end
  end

  @doc "Session run options for a new session: Codex controls, machine grants, workflow."
  @spec start_opts(socket()) :: keyword()
  def start_opts(socket) do
    run_opts(socket.assigns.codex_prefs) ++
      machine_opts(socket.assigns.machine_prefs) ++
      workflow_opts(socket.assigns.workflow_prefs)
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

  @doc """
  Applies a workflow picked in the UI to the preference and the live session.

  The empty select value picks the default chain (the session's `:workflow`
  key is deleted). A named selection is validated against the live registry
  BEFORE it is persisted or configured — an unknown name would otherwise fail
  every subsequent run — and rejection leaves prefs and session untouched.
  """
  @spec select_workflow(socket(), term()) :: socket()
  def select_workflow(socket, value) do
    case normalize_workflow(value) do
      {:ok, workflow} ->
        apply_workflow(socket, workflow)

      {:error, reason} ->
        put_flash(socket, :error, workflow_error(reason))
    end
  end

  @doc """
  Picker rows for the workflow select: the live registry list plus a bare
  `:unavailable` entry when the current selection is missing from it, so the
  browser cannot silently display another workflow (the Codex model picker
  desync lesson from P5a applies here unchanged).
  """
  @spec workflow_options(workflow_prefs()) :: [workflow_option()]
  def workflow_options(prefs) do
    rows = WorkflowRegistry.list()

    case prefs.workflow do
      nil ->
        rows

      name ->
        case Enum.any?(rows, &(&1.name == name)) do
          true -> rows
          false -> rows ++ [%{name: name, module: nil, source: :unavailable}]
        end
    end
  end

  @doc """
  Reconciles the workflow preference from a session's authoritative options.

  Unlike the computer-use grant, reconciliation is unconditional: a missing
  `:workflow` key has a defined meaning (the default chain), so an attached
  session without one must show — and persist — "default" rather than keep a
  stale browser preference the session does not have.
  """
  @spec sync_workflow_from_opts(socket(), keyword()) :: socket()
  def sync_workflow_from_opts(socket, opts) do
    prefs = %{workflow: valid_workflow_opt(Keyword.get(opts, :workflow))}
    persist(@workflow_prefs_ptr, prefs)
    assign(socket, workflow_prefs: prefs)
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
    {:ok, snapshot} = Models.catalog_snapshot(provider(prefs), prefs.model)
    snapshot
  end

  @doc """
  Builds the registry-resolved model used to start a session.

  Provider selection is deliberately left to the model API's live registry
  entry, so no provider is returned here.
  """
  @spec provider_config(codex_prefs()) :: Catalyst.Model.t()
  def provider_config(prefs) do
    {:ok, model} = Models.build(provider(prefs), prefs.model)
    model
  end

  @doc "Converts the selected provider's controls into session run options."
  @spec run_opts(codex_prefs()) :: keyword()
  def run_opts(prefs) do
    entry = catalog_snapshot(prefs).selected

    service_tier =
      case prefs.fast and entry.fast? do
        true -> "priority"
        false -> nil
      end

    [
      reasoning_effort: prefs.effort,
      service_tier: service_tier,
      transport: supported_transport(entry, prefs.transport)
    ]
  end

  @doc "Token-store provider for the selected model."
  @spec auth_provider(codex_prefs()) :: String.t()
  def auth_provider(prefs), do: catalog_snapshot(prefs).selected.auth.provider_id()

  @doc "Human-facing subscription name for the selected model."
  @spec auth_label(codex_prefs()) :: String.t()
  def auth_label(prefs), do: catalog_snapshot(prefs).selected.provider_name

  @doc """
  Synchronizes controls from an attached session, which is the source of truth.

  Reconciles both the Codex controls (`codex_prefs`) and the machine-capability
  grants (`machine_prefs`, i.e. the computer-use toggle) from the session's
  authoritative options — a session configured directly, or a reattach to a
  different session, must never leave the SAFETY toggle showing a state the
  session does not have. `machine_prefs` stays its own persistent term (see the
  module attribute comment); only its `:computer_use` key is reconciled here,
  and only when the session actually carries the option, so a browser-level
  preference for a genuinely new session is never clobbered by a session that
  predates the capability.
  """
  @spec sync_from_session(socket()) :: socket()
  def sync_from_session(socket) do
    model = socket.assigns.session_model || provider_config(socket.assigns.codex_prefs)
    opts = socket.assigns.session_opts || []
    provider = provider_from_model(model, socket.assigns.codex_prefs)

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
    |> sync_machine_from_opts(opts)
    |> sync_workflow_from_opts(opts)
  end

  # The session's :computer_use option wins over the browser preference exactly
  # as the Codex options do above — but only when the option is present; a
  # session without the key (older session, external configurer) must not turn
  # a persisted grant preference off behind the user's back.
  defp sync_machine_from_opts(socket, opts) do
    case Keyword.fetch(opts, :computer_use) do
      {:ok, granted} when is_boolean(granted) ->
        prefs = Map.put(socket.assigns.machine_prefs, :computer_use, granted)
        persist(@machine_prefs_ptr, prefs)
        assign(socket, machine_prefs: prefs)

      _absent_or_invalid ->
        socket
    end
  end

  # Only the capability key is sent: `Server.configure/2` merges opts, so the
  # session's Codex tuning stays exactly as it was.
  defp configure_machine(socket, pid, prefs) do
    opts = machine_opts(prefs)

    try do
      :ok = Server.configure(pid, opts: opts)
      assign(socket, session_opts: Keyword.merge(socket.assigns.session_opts || [], opts))
    catch
      :exit, _reason -> socket
    end
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

  defp normalize_workflow(""), do: {:ok, nil}

  defp normalize_workflow(name) when is_binary(name) do
    case WorkflowRegistry.fetch(name) do
      {:ok, _module} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_workflow(other), do: {:error, {:invalid_workflow, other}}

  defp apply_workflow(socket, workflow) do
    case socket.assigns.session_pid do
      pid when is_pid(pid) -> configure_workflow(socket, pid, workflow)
      _no_session -> commit_workflow(socket, workflow)
    end
  end

  defp configure_workflow(socket, pid, workflow) do
    current = socket.assigns.workflow_prefs.workflow

    case external_backend_switch?(current, workflow) and backend_boundary_present?(pid) do
      true ->
        socket
        |> commit_workflow(workflow)
        |> SessionLifecycle.start()

      false ->
        configure_current_workflow(socket, pid, workflow)
    end
  end

  defp configure_current_workflow(socket, pid, workflow) do
    opts = [workflow: workflow]

    try do
      case Server.configure(pid, opts: opts) do
        :ok ->
          socket
          |> commit_workflow(workflow)
          # Mirror the server's merge semantics locally: a nil value DELETES the
          # key, so the assigns never show a workflow the session no longer has.
          |> assign(session_opts: merge_local_opts(socket.assigns.session_opts || [], opts))

        {:error, reason} ->
          put_flash(socket, :error, workflow_error(reason))
      end
    catch
      # The session can die during a control change. The monitor callback will
      # reattach and reconcile the preference from its authoritative options.
      :exit, _reason -> put_flash(socket, :error, "Session is restarting — try again.")
    end
  end

  defp external_backend_switch?(workflow, workflow), do: false

  defp external_backend_switch?(current, selected),
    do: external_workflow?(current) or external_workflow?(selected)

  defp external_workflow?("claude-code"), do: true
  defp external_workflow?("acp/" <> _agent_id), do: true
  defp external_workflow?(_workflow), do: false

  defp backend_boundary_present?(pid) do
    snapshot = Server.state(pid)
    snapshot.running or snapshot.messages != []
  catch
    :exit, _reason -> false
  end

  defp commit_workflow(socket, workflow) do
    prefs = %{workflow: workflow}
    persist(@workflow_prefs_ptr, prefs)
    assign(socket, workflow_prefs: prefs)
  end

  defp merge_local_opts(opts, changes) do
    Enum.reduce(changes, opts, fn
      {key, nil}, acc -> Keyword.delete(acc, key)
      {key, value}, acc -> Keyword.put(acc, key, value)
    end)
  end

  defp valid_workflow_opt(name) when is_binary(name), do: name
  defp valid_workflow_opt(_absent_or_invalid), do: nil

  defp workflow_error({:unknown_workflow, name}) do
    "workflow #{inspect(name)} is no longer available (its extension may have been unloaded) — pick another or default"
  end

  defp workflow_error(reason), do: "could not select workflow: #{inspect(reason)}"

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
    case Models.infer_provider(prefs.model) do
      {:ok, provider} -> Map.put(prefs, :provider, provider)
      {:error, _unknown_or_ambiguous} -> prefs
    end
  end

  defp provider_from_model(model, prefs) do
    case Models.provider_id(model) do
      {:ok, provider} -> provider
      {:error, _unknown_or_legacy} -> provider(prefs)
    end
  end

  defp default_effort(provider) do
    model = default_model_id(provider)
    selected_entry(provider, model).default_effort
  end

  defp default_model_id(provider) do
    {:ok, model} = Models.default_model_id(provider)
    model
  end

  defp selected_entry(provider, model) do
    {:ok, snapshot} = Models.catalog_snapshot(provider, model)
    snapshot.selected
  end

  defp supported_transport(entry, transport) do
    case entry.controls[:transports] do
      transports when is_list(transports) and transports != [] -> transport
      _unsupported -> nil
    end
  end

  defp provider(prefs) do
    default = default_selection().provider_id
    requested = Map.get(prefs, :provider, default)

    case Models.default_model_id(requested) do
      {:ok, _model_id} -> requested
      {:error, _reason} -> default
    end
  end

  defp default_selection do
    {:ok, selection} = Models.default_selection()
    selection
  end

  defp persist(key, prefs), do: :persistent_term.put(key, prefs)
end
