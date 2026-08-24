defmodule CatalystWeb.Pages.ComparisonPage do
  @moduledoc """
  Creates and displays durable multi-model comparisons.

  Each lane renders in its own nested LiveView. This parent owns only clone
  provisioning, lane membership, and shared prompt dispatch.
  """

  use CatalystWeb, :live_view

  alias Catalyst.Comparison

  @doc false
  def mount_page(params, socket) do
    selected_model = Catalyst.LLM.OpenAICodex.model().id
    models = Catalyst.LLM.OpenAICodex.catalog_snapshot(selected_model).models
    options = Enum.map(models, &{&1.name, &1.id})
    default = models |> List.first() |> Map.fetch!(:id)
    second = models |> Enum.at(1, List.first(models)) |> Map.fetch!(:id)
    source = default_cwd()

    socket =
      assign(socket,
        comparison: nil,
        comparisons: Comparison.list(),
        model_options: options,
        creating?: false,
        adding?: false,
        dispatching?: false,
        create_form:
          to_form(
            %{
              "source" => source,
              "model_a" => default,
              "model_b" => second,
              "system_prompt" => ""
            },
            as: :comparison
          ),
        add_form: to_form(%{"model" => default}, as: :lane),
        shared_form: to_form(%{"message" => ""}, as: :shared)
      )

    socket =
      socket
      |> load_comparison(params)
      |> subscribe_comparison()

    socket
  end

  @impl true
  def handle_event("create", %{"comparison" => params}, socket) do
    source = String.trim(params["source"] || "")
    models = [params["model_a"], params["model_b"]]
    prompt = blank_to_nil(params["system_prompt"])

    {:noreply,
     socket
     |> assign(
       creating?: true,
       create_form: to_form(params, as: :comparison)
     )
     |> start_async(:create_comparison, fn ->
       Comparison.create(source, models, system_prompt: prompt)
     end)}
  end

  def handle_event("add_lane", %{"lane" => %{"model" => model}}, socket) do
    comparison_id = socket.assigns.comparison["id"]

    {:noreply,
     socket
     |> assign(adding?: true)
     |> start_async(:add_lane, fn ->
       Comparison.add_lane(comparison_id, model)
     end)}
  end

  def handle_event("send_shared", _params, %{assigns: %{dispatching?: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("send_shared", %{"shared" => params}, socket) do
    lane_ids = List.wrap(params["lanes"])
    text = params["message"] || ""
    comparison_id = socket.assigns.comparison["id"]

    {:noreply,
     socket
     |> assign(
       dispatching?: true,
       shared_form: to_form(params, as: :shared)
     )
     |> start_async(:dispatch, fn ->
       Comparison.dispatch(comparison_id, lane_ids, text)
     end)}
  end

  @impl true
  def handle_async(:create_comparison, {:ok, {:ok, comparison}}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/compare/#{comparison["id"]}")}
  end

  def handle_async(:create_comparison, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(creating?: false)
     |> put_flash(:error, comparison_error(reason))}
  end

  def handle_async(:create_comparison, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(creating?: false)
     |> put_flash(:error, "Comparison creation crashed: #{inspect(reason)}")}
  end

  def handle_async(:add_lane, {:ok, {:ok, comparison}}, socket) do
    {:noreply,
     socket
     |> assign(comparison: comparison, adding?: false)
     |> put_flash(:info, "Lane added from a fresh project snapshot.")}
  end

  def handle_async(:add_lane, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(adding?: false)
     |> put_flash(:error, comparison_error(reason))}
  end

  def handle_async(:add_lane, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(adding?: false)
     |> put_flash(:error, "Adding the lane crashed: #{inspect(reason)}")}
  end

  def handle_async(:dispatch, {:ok, {:ok, outcomes}}, socket) do
    {:noreply,
     socket
     |> assign(
       dispatching?: false,
       shared_form: to_form(%{"message" => ""}, as: :shared)
     )
     |> put_flash(:info, dispatch_message(outcomes))}
  end

  def handle_async(:dispatch, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(dispatching?: false)
     |> put_flash(:error, comparison_error(reason))}
  end

  def handle_async(:dispatch, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(dispatching?: false)
     |> put_flash(:error, "Shared dispatch crashed: #{inspect(reason)}")}
  end

  @impl true
  def handle_info(
        {:comparison_updated, id, comparison},
        %{assigns: %{comparison: %{"id" => id}}} = socket
      ) do
    {:noreply, assign(socket, comparison: comparison)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="comparison-view" class="flex h-full min-h-0 flex-col">
        <header class="flex h-12 shrink-0 items-center gap-3 border-b border-edge bg-surface px-4">
          <.link
            navigate={~p"/"}
            id="comparison-back"
            class="flex size-8 items-center justify-center rounded-lg text-muted transition hover:bg-raised hover:text-ink"
            title="Back to Catalyst"
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <div class="min-w-0">
            <h1 class="truncate text-sm font-semibold">
              {if(@comparison, do: @comparison["title"], else: "Model comparison")}
            </h1>
            <p :if={@comparison} class="truncate font-mono text-[10px] text-faint">
              {@comparison["source_root"]}
            </p>
          </div>
        </header>

        <%= if @comparison do %>
          <section
            id="comparison-lanes"
            class="min-h-0 flex-1 overflow-x-auto overflow-y-hidden p-3"
          >
            <div class="grid h-full auto-cols-[minmax(28rem,1fr)] grid-flow-col gap-3">
              <div
                :for={lane <- @comparison["lanes"]}
                id={"comparison-lane-host-#{lane["id"]}"}
                class="h-full min-w-0"
              >
                {live_render(@socket, CatalystWeb.ComparisonLaneLive,
                  id: "comparison-lane-live-#{lane["id"]}",
                  session: %{
                    "comparison_id" => @comparison["id"],
                    "lane_id" => lane["id"]
                  }
                )}
              </div>

              <aside
                id="add-lane-card"
                class="flex h-full min-h-80 items-center justify-center rounded-2xl border border-dashed border-edge-strong bg-surface/40 p-6"
              >
                <.form
                  for={@add_form}
                  id="add-lane-form"
                  phx-submit="add_lane"
                  class="w-full max-w-xs"
                >
                  <div class="mb-4 flex size-10 items-center justify-center rounded-xl bg-accent/10 text-accent">
                    <.icon name="hero-plus" class="size-5" />
                  </div>
                  <h2 class="text-sm font-semibold">Add another model</h2>
                  <p class="mt-1 text-xs leading-5 text-muted">
                    Captures a fresh snapshot of the original project.
                  </p>
                  <.input
                    field={@add_form[:model]}
                    type="select"
                    id="add-lane-model"
                    options={@model_options}
                    container_class="my-4"
                  />
                  <button
                    id="add-lane-submit"
                    type="submit"
                    disabled={@adding?}
                    class="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-accent px-4 py-2.5 text-xs font-semibold text-white transition hover:bg-accent/90 disabled:cursor-wait disabled:opacity-60"
                  >
                    <.icon
                      name={if(@adding?, do: "hero-arrow-path", else: "hero-plus")}
                      class={["size-4", @adding? && "animate-spin"]}
                    />
                    {if(@adding?, do: "Creating clone…", else: "Add lane")}
                  </button>
                </.form>
              </aside>
            </div>
          </section>

          <footer class="shrink-0 border-t border-edge bg-surface px-3 py-2">
            <.form
              for={@shared_form}
              id="shared-prompt-form"
              phx-submit="send_shared"
              class="mx-auto max-w-5xl"
            >
              <div class="mb-1.5 flex flex-wrap items-center gap-1.5">
                <span class="mr-1 text-[10px] font-semibold uppercase tracking-wider text-faint">
                  Send to
                </span>
                <label
                  :for={lane <- @comparison["lanes"]}
                  class="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-edge px-2 py-1 text-[10px] font-medium text-muted transition has-[:checked]:border-accent/40 has-[:checked]:bg-accent/10 has-[:checked]:text-accent"
                >
                  <input
                    id={"shared-lane-#{lane["id"]}"}
                    type="checkbox"
                    name="shared[lanes][]"
                    value={lane["id"]}
                    checked
                    class="size-3 rounded border-edge-strong text-accent focus:ring-accent"
                  />
                  <span id={"shared-lane-label-#{lane["id"]}"}>{lane["model_id"]}</span>
                </label>
              </div>
              <div class="flex items-end gap-2 rounded-2xl border border-edge bg-raised px-3 py-2 shadow-sm focus-within:border-accent focus-within:ring-2 focus-within:ring-accent/20">
                <.input
                  field={@shared_form[:message]}
                  type="textarea"
                  id="shared-prompt-input"
                  rows="1"
                  placeholder="Ask every selected model…"
                  container_class="m-0 min-w-0 flex-1"
                  class="w-full resize-none border-0 bg-transparent px-0 py-1 text-sm leading-6 text-ink outline-none placeholder:text-faint focus:ring-0"
                />
                <button
                  id="shared-prompt-submit"
                  type="submit"
                  disabled={@dispatching?}
                  class="flex size-8 shrink-0 items-center justify-center rounded-xl bg-accent text-white shadow-sm transition hover:bg-accent/90 disabled:cursor-wait disabled:opacity-60"
                  aria-label="Send shared prompt"
                >
                  <.icon
                    name={if(@dispatching?, do: "hero-arrow-path", else: "hero-arrow-up")}
                    class={["size-4", @dispatching? && "animate-spin"]}
                  />
                </button>
              </div>
            </.form>
          </footer>
        <% else %>
          <section class="min-h-0 flex-1 overflow-y-auto px-5 py-10">
            <div class="mx-auto grid max-w-5xl gap-8 lg:grid-cols-[1.2fr_0.8fr]">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-accent">
                  Independent workspaces
                </p>
                <h2 class="mt-3 max-w-xl text-3xl font-semibold tracking-tight">
                  Compare models against the same project snapshot.
                </h2>
                <p class="mt-3 max-w-xl text-sm leading-6 text-muted">
                  Catalyst creates two private Git clones containing HEAD, tracked changes, and non-ignored untracked files.
                </p>

                <div id="comparison-list" class="mt-8 space-y-2">
                  <.link
                    :for={comparison <- @comparisons}
                    navigate={~p"/compare/#{comparison["id"]}"}
                    id={"open-comparison-#{comparison["id"]}"}
                    class="flex items-center gap-3 rounded-xl border border-edge bg-surface p-3 transition hover:border-accent/40 hover:shadow-sm"
                  >
                    <div class="flex size-9 items-center justify-center rounded-lg bg-raised">
                      <.icon name="hero-squares-2x2" class="size-4 text-muted" />
                    </div>
                    <div class="min-w-0 flex-1">
                      <p class="truncate text-sm font-medium">{comparison["title"]}</p>
                      <p class="truncate text-[10px] text-faint">
                        {length(comparison["lanes"])} lanes · {comparison["updated_at"]}
                      </p>
                    </div>
                    <.icon name="hero-chevron-right" class="size-4 text-faint" />
                  </.link>
                </div>
              </div>

              <.form
                for={@create_form}
                id="create-comparison-form"
                phx-submit="create"
                class="rounded-2xl border border-edge bg-surface p-5 shadow-sm"
              >
                <h2 class="text-sm font-semibold">New comparison</h2>
                <p class="mt-1 text-xs text-muted">
                  The initial lanes share one frozen snapshot.
                </p>
                <.input
                  field={@create_form[:source]}
                  id="comparison-source"
                  label="Project directory"
                  autocomplete="off"
                  class="w-full rounded-xl border border-edge bg-raised px-3 py-2 text-sm text-ink outline-none transition focus:border-accent focus:ring-2 focus:ring-accent/20"
                  container_class="mt-5"
                />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@create_form[:model_a]}
                    type="select"
                    id="comparison-model-a"
                    label="Left model"
                    options={@model_options}
                    container_class="mt-4"
                  />
                  <.input
                    field={@create_form[:model_b]}
                    type="select"
                    id="comparison-model-b"
                    label="Right model"
                    options={@model_options}
                    container_class="mt-4"
                  />
                </div>
                <.input
                  field={@create_form[:system_prompt]}
                  type="textarea"
                  id="comparison-system-prompt"
                  label="System prompt override"
                  rows="5"
                  placeholder="Blank inherits Catalyst's effective system prompt."
                  class="w-full resize-y rounded-xl border border-edge bg-raised px-3 py-2 text-sm leading-5 text-ink outline-none transition focus:border-accent focus:ring-2 focus:ring-accent/20"
                  container_class="mt-4"
                />
                <button
                  id="create-comparison-submit"
                  type="submit"
                  disabled={@creating?}
                  class="mt-2 inline-flex w-full items-center justify-center gap-2 rounded-xl bg-accent px-4 py-3 text-sm font-semibold text-white shadow-sm transition hover:bg-accent/90 disabled:cursor-wait disabled:opacity-60"
                >
                  <.icon
                    name={if(@creating?, do: "hero-arrow-path", else: "hero-squares-2x2")}
                    class={["size-4", @creating? && "animate-spin"]}
                  />
                  {if(@creating?, do: "Capturing and cloning…", else: "Create comparison")}
                </button>
              </.form>
            </div>
          </section>
        <% end %>
    </main>
    """
  end

  defp load_comparison(socket, %{"path" => ["compare", id]}) do
    case Comparison.get(id) do
      {:ok, comparison} -> assign(socket, comparison: comparison)
      {:error, reason} -> put_flash(socket, :error, comparison_error(reason))
    end
  end

  defp load_comparison(socket, _params), do: socket

  defp subscribe_comparison(%{assigns: %{comparison: %{"id" => id}}} = socket) do
    case connected?(socket) do
      true ->
        Phoenix.PubSub.subscribe(Catalyst.PubSub, Comparison.comparison_topic(id))
        socket

      false ->
        socket
    end
  end

  defp subscribe_comparison(socket), do: socket

  defp default_cwd do
    case Catalyst.Paths.default_cwd() do
      {:ok, cwd} -> cwd
      {:error, _reason} -> ""
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  defp dispatch_message(outcomes) do
    started = Enum.count(outcomes, &match?({_id, :started}, &1))
    queued = Enum.count(outcomes, &match?({_id, :queued}, &1))
    failed = map_size(outcomes) - started - queued
    "Shared prompt: #{started} started, #{queued} queued, #{failed} failed."
  end

  defp comparison_error(:blank_prompt), do: "Enter a prompt."
  defp comparison_error(:no_recipients), do: "Select at least one lane."
  defp comparison_error(:comparison_not_found), do: "Comparison not found."
  defp comparison_error(reason), do: "Comparison failed: #{inspect(reason)}"
end
