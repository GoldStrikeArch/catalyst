defmodule CatalystWeb.Pages.WorkflowsPage do
  @moduledoc "Built-in vertical workflow template builder."

  use CatalystWeb, :html

  alias CatalystWeb.ShellLive.Workflows

  @doc false
  @spec mount_page(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mount_page(_params, socket) do
    case Map.has_key?(socket.assigns, :workflow_template) do
      true -> Workflows.refresh(socket)
      false -> socket |> Workflows.init() |> Workflows.refresh()
    end
  end

  @doc false
  def handle_event("workflow_select", %{"id" => id}, socket),
    do: {:noreply, Workflows.select(socket, id)}

  def handle_event("workflow_create", _params, socket),
    do: {:noreply, Workflows.create(socket)}

  def handle_event("workflow_clone", %{"id" => id}, socket),
    do: {:noreply, Workflows.clone(socket, id)}

  def handle_event("workflow_add_stage", %{"preset" => preset}, socket),
    do: {:noreply, Workflows.add_stage(socket, preset)}

  def handle_event("workflow_select_stage", %{"id" => id}, socket),
    do: {:noreply, Workflows.select_stage(socket, id)}

  def handle_event("workflow_update_stage", %{"stage_id" => id} = params, socket),
    do: {:noreply, Workflows.update_stage(socket, id, Map.delete(params, "stage_id"))}

  def handle_event("workflow_move_stage", %{"id" => id, "direction" => direction}, socket),
    do: {:noreply, Workflows.move_stage(socket, id, direction)}

  def handle_event("workflow_delete_stage", %{"id" => id}, socket),
    do: {:noreply, Workflows.delete_stage(socket, id)}

  def handle_event("workflow_save", params, socket),
    do: {:noreply, Workflows.save(socket, params)}

  def handle_event("workflow_delete", _params, socket),
    do: {:noreply, Workflows.delete(socket)}

  def handle_event("workflow_resume_run", %{"id" => id}, socket),
    do: {:noreply, Workflows.resume_run(socket, id)}

  @doc false
  def handle_info({:workflow_run_event, _id, event}, socket),
    do: {:noreply, Workflows.run_event(socket, event)}

  @doc "Renders workflow templates and the selected connected-stage editor."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <main id="workflows-page" class="flex-1 overflow-y-auto px-4 py-6 sm:px-6">
      <div class="mx-auto grid max-w-7xl gap-5 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <aside class="space-y-4">
          <header class="rounded-2xl border border-edge bg-surface p-4 shadow-sm">
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-accent">
                  Library
                </p>
                <h1 class="mt-1 text-lg font-semibold text-ink">Workflows</h1>
              </div>
              <button
                id="workflow-create"
                phx-click="workflow_create"
                class="rounded-full bg-accent p-2 text-white shadow-sm transition hover:-translate-y-px hover:bg-accent/90"
                title="Create workflow"
              >
                <.icon name="hero-plus" class="size-4" />
              </button>
            </div>
            <p class="mt-2 text-xs leading-5 text-muted">
              Compose reliable agent runs from connected, ordered stages.
            </p>
          </header>

          <section
            :if={!@workflow_runs_empty?}
            id="workflow-run-list"
            class="rounded-2xl border border-edge bg-surface p-4 shadow-sm"
          >
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-muted">
              Recent runs
            </p>
            <div id="workflow-runs" phx-update="stream" class="mt-3 space-y-2">
              <div
                :for={{dom_id, run} <- @streams.workflow_runs}
                id={dom_id}
                class="flex items-center justify-between gap-3 rounded-xl bg-raised px-3 py-2"
              >
                <div class="min-w-0">
                  <p class="truncate text-xs font-medium">{run["id"]}</p>
                  <p class="mt-0.5 text-[0.65rem] uppercase tracking-wide text-muted">
                    {run["status"]} · stage {run["stage_index"] + 1}/{length(run["stages"])}
                  </p>
                </div>
                <button
                  :if={run["status"] == "interrupted"}
                  id={"workflow-run-resume-#{run["id"]}"}
                  type="button"
                  phx-click="workflow_resume_run"
                  phx-value-id={run["id"]}
                  class="rounded-full bg-accent px-3 py-1.5 text-[0.65rem] font-semibold text-white transition hover:bg-accent/90"
                >
                  Resume
                </button>
              </div>
            </div>
          </section>

          <p
            :if={@workflow_error}
            id="workflow-store-error"
            class="rounded-xl border border-amber-200 bg-amber-50 p-3 text-xs text-amber-800"
          >
            {@workflow_error}
          </p>

          <nav id="workflow-template-list" phx-update="stream" class="space-y-2">
            <button
              :for={{dom_id, template} <- @streams.workflow_templates}
              id={dom_id}
              type="button"
              phx-click="workflow_select"
              phx-value-id={template_id(template)}
              class={[
                "group w-full rounded-xl border px-3 py-3 text-left transition hover:-translate-y-px hover:shadow-sm",
                selected?(@workflow_template, template) &&
                  "border-accent/40 bg-accent/10",
                !selected?(@workflow_template, template) &&
                  "border-edge bg-surface hover:border-edge-strong"
              ]}
            >
              <span class="flex items-center justify-between gap-2">
                <span class="truncate text-sm font-semibold">{template_name(template)}</span>
                <span
                  :if={built_in?(template)}
                  class="rounded-full bg-raised px-2 py-0.5 text-[0.6rem] font-semibold uppercase tracking-wide text-muted"
                >
                  Built-in
                </span>
              </span>
              <span class="mt-1 block line-clamp-2 text-xs leading-5 text-muted">
                {template_description(template)}
              </span>
            </button>
          </nav>
        </aside>

        <section
          :if={@workflow_template == :none}
          id="workflow-empty"
          class="grid min-h-[32rem] place-items-center rounded-3xl border border-dashed border-edge-strong bg-surface/50 p-8 text-center"
        >
          <div class="max-w-sm">
            <span class="mx-auto grid size-12 place-items-center rounded-2xl bg-accent/10 text-accent">
              <.icon name="hero-queue-list" class="size-6" />
            </span>
            <h2 class="mt-4 text-base font-semibold">Select a workflow to begin</h2>
            <p class="mt-2 text-sm leading-6 text-muted">
              Inspect a built-in template, clone it as a starting point, or create a blank workflow.
            </p>
          </div>
        </section>

        <section :if={is_map(@workflow_template)} id="workflow-editor" class="space-y-5">
          <.form
            for={@workflow_form}
            id="workflow-template-form"
            phx-submit="workflow_save"
            class="rounded-2xl border border-edge bg-surface p-5 shadow-sm"
          >
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="min-w-0 flex-1 space-y-3">
                <.input
                  field={@workflow_form[:name]}
                  id="workflow-name"
                  label="Workflow name"
                  disabled={built_in?(@workflow_template)}
                />
                <.input
                  field={@workflow_form[:description]}
                  id="workflow-description"
                  type="textarea"
                  rows="2"
                  label="Description"
                  disabled={built_in?(@workflow_template)}
                />
              </div>
              <div class="flex items-center gap-2">
                <button
                  :if={built_in?(@workflow_template)}
                  id="workflow-clone"
                  type="button"
                  phx-click="workflow_clone"
                  phx-value-id={template_id(@workflow_template)}
                  class="rounded-full bg-accent px-4 py-2 text-xs font-semibold text-white transition hover:-translate-y-px hover:bg-accent/90"
                >
                  Clone to edit
                </button>
                <button
                  :if={!built_in?(@workflow_template)}
                  id="workflow-delete"
                  type="button"
                  phx-click="workflow_delete"
                  data-confirm="Delete this workflow template?"
                  class="rounded-full px-3 py-2 text-xs font-semibold text-danger transition hover:bg-danger/10"
                >
                  Delete
                </button>
                <button
                  :if={!built_in?(@workflow_template)}
                  id="workflow-save"
                  type="submit"
                  class="rounded-full bg-accent px-4 py-2 text-xs font-semibold text-white transition hover:-translate-y-px hover:bg-accent/90"
                >
                  Validate & save
                </button>
              </div>
            </div>
          </.form>

          <div
            :if={!built_in?(@workflow_template)}
            id="workflow-preset-palette"
            class="flex flex-wrap items-center gap-2 rounded-2xl border border-edge bg-surface p-3 shadow-sm"
          >
            <span class="mr-1 text-xs font-semibold text-muted">Add stage</span>
            <button
              :for={{label, preset} <- @workflow_presets}
              id={"workflow-add-#{preset}"}
              type="button"
              phx-click="workflow_add_stage"
              phx-value-preset={preset}
              class="rounded-full border border-edge px-3 py-1.5 text-xs font-medium transition hover:border-accent/40 hover:bg-accent/10 hover:text-accent"
            >
              <.icon name="hero-plus-small" class="mr-1 inline size-3.5" />{label}
            </button>
          </div>

          <div
            id="workflow-stage-builder"
            class="grid items-start gap-5 xl:grid-cols-[minmax(16rem,0.72fr)_minmax(0,1.28fr)]"
          >
            <section
              id="workflow-stage-map"
              class="rounded-2xl border border-edge bg-raised p-4 shadow-sm"
            >
              <header class="mb-4 flex items-center justify-between gap-3">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.18em] text-accent">
                    Flow
                  </p>
                  <p class="mt-1 text-xs text-muted">Select a stage to inspect its settings.</p>
                </div>
                <span class="rounded-full bg-surface px-2.5 py-1 text-[0.65rem] font-semibold text-muted shadow-sm ring-1 ring-edge">
                  {length(template_stages(@workflow_template))} stages
                </span>
              </header>

              <div class="mx-auto max-w-sm">
                <div class="mx-auto flex h-10 w-36 items-center justify-center rounded-lg border border-accent/40 bg-accent/10 px-3 text-xs font-semibold text-accent shadow-sm">
                  User task
                </div>
                <div class="mx-auto h-4 w-px bg-edge-strong"></div>

                <div
                  id="workflow-stage-list"
                  phx-update="stream"
                  class="space-y-2"
                >
                  <div
                    id="workflow-stage-empty"
                    class="hidden only:block rounded-xl border border-dashed border-edge-strong p-7 text-center text-xs text-muted"
                  >
                    Add the first stage from the preset palette.
                  </div>
                  <article
                    :for={{dom_id, stage} <- @streams.workflow_stages}
                    id={dom_id}
                    class="relative pt-4 first:pt-0 before:absolute before:left-1/2 before:top-0 before:h-4 before:w-px before:-translate-x-1/2 before:bg-edge-strong first:before:hidden"
                  >
                    <button
                      id={"workflow-stage-node-#{stage.id}"}
                      type="button"
                      phx-click="workflow_select_stage"
                      phx-value-id={stage.id}
                      aria-pressed={selected_stage?(@workflow_selected_stage, stage)}
                      class={[
                        "group mx-auto flex min-h-12 w-full max-w-[15rem] items-center gap-3 rounded-lg border bg-surface px-3 py-2 text-left shadow-sm transition duration-200 hover:-translate-y-px hover:border-accent/40 hover:shadow-md",
                        selected_stage?(@workflow_selected_stage, stage) &&
                          "border-accent ring-2 ring-accent/20",
                        !selected_stage?(@workflow_selected_stage, stage) &&
                          "border-edge"
                      ]}
                    >
                      <span class={[
                        "grid size-7 shrink-0 place-items-center rounded-md text-[0.65rem] font-bold transition",
                        selected_stage?(@workflow_selected_stage, stage) &&
                          "bg-accent text-white",
                        !selected_stage?(@workflow_selected_stage, stage) &&
                          "bg-raised text-muted group-hover:bg-accent/10 group-hover:text-accent"
                      ]}>
                        {stage.position}
                      </span>
                      <span class="min-w-0 flex-1">
                        <span class="block truncate text-xs font-semibold text-ink">
                          {stage_name(stage)}
                        </span>
                        <span class="mt-0.5 block truncate text-[0.65rem] capitalize text-muted">
                          {stage_profile(stage)} · {stage_effort(stage)} effort
                        </span>
                      </span>
                      <.icon
                        name="hero-chevron-right"
                        class={[
                          "size-3.5 shrink-0 transition",
                          selected_stage?(@workflow_selected_stage, stage) &&
                            "text-accent",
                          !selected_stage?(@workflow_selected_stage, stage) &&
                            "text-faint group-hover:text-accent"
                        ]}
                      />
                    </button>
                  </article>
                </div>

                <div
                  :if={template_stages(@workflow_template) != []}
                  class="mx-auto h-4 w-px bg-edge-strong"
                >
                </div>
                <div
                  :if={template_stages(@workflow_template) != []}
                  class="mx-auto flex h-10 w-36 items-center justify-center rounded-lg border border-ok/40 bg-ok/10 px-3 text-xs font-semibold text-ok shadow-sm"
                >
                  Final result
                </div>
              </div>
            </section>

            <aside
              :if={@workflow_selected_stage == :none}
              id="workflow-stage-inspector-empty"
              class="grid min-h-72 place-items-center rounded-2xl border border-dashed border-edge-strong bg-surface/40 p-8 text-center xl:sticky xl:top-4"
            >
              <div class="max-w-xs">
                <span class="mx-auto grid size-11 place-items-center rounded-xl bg-accent/10 text-accent">
                  <.icon name="hero-cursor-arrow-rays" class="size-5" />
                </span>
                <h3 class="mt-3 text-sm font-semibold">Choose a stage</h3>
                <p class="mt-1.5 text-xs leading-5 text-muted">
                  Stage metadata stays tucked away until you select a block in the flow.
                </p>
              </div>
            </aside>

            <aside
              :if={is_map(@workflow_selected_stage)}
              id="workflow-stage-inspector"
              class="rounded-2xl border border-edge bg-surface p-5 shadow-sm xl:sticky xl:top-4"
            >
              <div class="mb-5 flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <p class="text-xs font-semibold uppercase tracking-[0.18em] text-accent">
                    Stage settings
                  </p>
                  <h3 class="mt-1 truncate text-base font-semibold">
                    {stage_name(@workflow_selected_stage)}
                  </h3>
                </div>
                <div :if={!built_in?(@workflow_template)} class="flex shrink-0 gap-1">
                  <button
                    id={"workflow-stage-up-#{@workflow_selected_stage.id}"}
                    type="button"
                    phx-click="workflow_move_stage"
                    phx-value-id={@workflow_selected_stage.id}
                    phx-value-direction="up"
                    class="rounded-lg p-2 text-faint transition hover:bg-raised hover:text-ink"
                    title="Move stage up"
                  >
                    <.icon name="hero-chevron-up" class="size-4" />
                  </button>
                  <button
                    id={"workflow-stage-down-#{@workflow_selected_stage.id}"}
                    type="button"
                    phx-click="workflow_move_stage"
                    phx-value-id={@workflow_selected_stage.id}
                    phx-value-direction="down"
                    class="rounded-lg p-2 text-faint transition hover:bg-raised hover:text-ink"
                    title="Move stage down"
                  >
                    <.icon name="hero-chevron-down" class="size-4" />
                  </button>
                  <button
                    id={"workflow-stage-delete-#{@workflow_selected_stage.id}"}
                    type="button"
                    phx-click="workflow_delete_stage"
                    phx-value-id={@workflow_selected_stage.id}
                    class="rounded-lg p-2 text-faint transition hover:bg-danger/10 hover:text-danger"
                    title="Delete stage"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </div>

              <.form
                for={@workflow_selected_stage.form}
                id={"workflow-stage-form-#{@workflow_selected_stage.id}"}
                phx-change="workflow_update_stage"
                class="space-y-4"
              >
                <input type="hidden" name="stage_id" value={@workflow_selected_stage.id} />
                <.input
                  field={@workflow_selected_stage.form[:name]}
                  id={"workflow-stage-name-#{@workflow_selected_stage.id}"}
                  label="Stage name"
                  disabled={built_in?(@workflow_template)}
                />
                <.input
                  field={@workflow_selected_stage.form[:instructions]}
                  id={"workflow-stage-instructions-#{@workflow_selected_stage.id}"}
                  type="textarea"
                  rows="4"
                  label="Instructions"
                  disabled={built_in?(@workflow_template)}
                />
                <div class="grid gap-3 sm:grid-cols-2">
                  <.input
                    field={@workflow_selected_stage.form[:profile]}
                    id={"workflow-stage-profile-#{@workflow_selected_stage.id}"}
                    type="select"
                    label="Profile"
                    options={[{"Coding", "coding"}, {"Inspect only", "inspect"}]}
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={@workflow_selected_stage.form[:model]}
                    id={"workflow-stage-model-#{@workflow_selected_stage.id}"}
                    label="Model override"
                    placeholder="Default"
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={@workflow_selected_stage.form[:effort]}
                    id={"workflow-stage-effort-#{@workflow_selected_stage.id}"}
                    type="select"
                    label="Effort"
                    options={[
                      {"Inherit", "inherit"},
                      {"Low", "low"},
                      {"Medium", "medium"},
                      {"High", "high"},
                      {"Extra high", "xhigh"},
                      {"Max", "max"},
                      {"Ultra", "ultra"}
                    ]}
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={@workflow_selected_stage.form[:attempts]}
                    id={"workflow-stage-attempts-#{@workflow_selected_stage.id}"}
                    type="number"
                    min="1"
                    max="5"
                    label="Attempts"
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={@workflow_selected_stage.form[:timeout_ms]}
                    id={"workflow-stage-timeout-#{@workflow_selected_stage.id}"}
                    type="number"
                    min="1000"
                    label="Timeout (ms)"
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={@workflow_selected_stage.form[:input_artifacts]}
                    id={"workflow-stage-artifacts-#{@workflow_selected_stage.id}"}
                    label="Input artifacts"
                    placeholder="plan.md, previous.diff"
                    disabled={built_in?(@workflow_template)}
                  />
                </div>
              </.form>
            </aside>
          </div>
        </section>
      </div>
    </main>
    """
  end

  defp template_id(template), do: value(template, :id, "")
  defp template_name(template), do: value(template, :name, "Untitled workflow")
  defp template_description(template), do: value(template, :description, "")
  defp template_stages(template), do: value(template, :stages, [])
  defp built_in?(template), do: value(template, :built_in, false)
  defp selected?(:none, _template), do: false
  defp selected?(selected, template), do: template_id(selected) == template_id(template)
  defp selected_stage?(:none, _stage), do: false
  defp selected_stage?(selected, stage), do: value(selected, :id, "") == value(stage, :id, "")
  defp stage_name(stage), do: value(stage, :name, "Untitled stage")
  defp stage_profile(stage), do: value(stage, :profile, "default")
  defp stage_effort(stage), do: value(stage, :effort, "inherit")
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
