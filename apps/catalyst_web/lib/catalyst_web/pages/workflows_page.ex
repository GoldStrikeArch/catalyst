defmodule CatalystWeb.Pages.WorkflowsPage do
  @moduledoc "Built-in vertical workflow template builder."

  use CatalystWeb, :html

  @doc "Renders workflow templates and the selected connected-stage editor."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <main id="workflows-page" class="flex-1 overflow-y-auto px-4 py-6 sm:px-6">
      <div class="mx-auto grid max-w-7xl gap-5 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <aside class="space-y-4">
          <header class="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm dark:border-white/10 dark:bg-white/5">
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-indigo-500">
                  Library
                </p>
                <h1 class="mt-1 text-lg font-semibold text-neutral-950 dark:text-white">Workflows</h1>
              </div>
              <button
                id="workflow-create"
                phx-click="workflow_create"
                class="rounded-full bg-neutral-900 p-2 text-white shadow-sm transition hover:-translate-y-px hover:bg-indigo-600 dark:bg-white dark:text-neutral-900"
                title="Create workflow"
              >
                <.icon name="hero-plus" class="size-4" />
              </button>
            </div>
            <p class="mt-2 text-xs leading-5 text-neutral-500">
              Compose reliable agent runs from connected, ordered stages.
            </p>
          </header>

          <section
            :if={!@workflow_runs_empty?}
            id="workflow-run-list"
            class="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm dark:border-white/10 dark:bg-white/5"
          >
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-neutral-500">
              Recent runs
            </p>
            <div id="workflow-runs" phx-update="stream" class="mt-3 space-y-2">
              <div
                :for={{dom_id, run} <- @streams.workflow_runs}
                id={dom_id}
                class="flex items-center justify-between gap-3 rounded-xl bg-neutral-50 px-3 py-2 dark:bg-white/5"
              >
                <div class="min-w-0">
                  <p class="truncate text-xs font-medium">{run["id"]}</p>
                  <p class="mt-0.5 text-[0.65rem] uppercase tracking-wide text-neutral-500">
                    {run["status"]} · stage {run["stage_index"] + 1}/{length(run["stages"])}
                  </p>
                </div>
                <button
                  :if={run["status"] == "interrupted"}
                  id={"workflow-run-resume-#{run["id"]}"}
                  type="button"
                  phx-click="workflow_resume_run"
                  phx-value-id={run["id"]}
                  class="rounded-full bg-indigo-600 px-3 py-1.5 text-[0.65rem] font-semibold text-white transition hover:bg-indigo-500"
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
                  "border-indigo-300 bg-indigo-50/80 dark:border-indigo-400/30 dark:bg-indigo-400/10",
                !selected?(@workflow_template, template) &&
                  "border-neutral-200 bg-white hover:border-neutral-300 dark:border-white/10 dark:bg-white/5"
              ]}
            >
              <span class="flex items-center justify-between gap-2">
                <span class="truncate text-sm font-semibold">{template_name(template)}</span>
                <span
                  :if={built_in?(template)}
                  class="rounded-full bg-neutral-100 px-2 py-0.5 text-[0.6rem] font-semibold uppercase tracking-wide text-neutral-500 dark:bg-white/10"
                >
                  Built-in
                </span>
              </span>
              <span class="mt-1 block line-clamp-2 text-xs leading-5 text-neutral-500">
                {template_description(template)}
              </span>
            </button>
          </nav>
        </aside>

        <section
          :if={@workflow_template == :none}
          id="workflow-empty"
          class="grid min-h-[32rem] place-items-center rounded-3xl border border-dashed border-neutral-300 bg-white/50 p-8 text-center dark:border-white/15 dark:bg-white/[0.03]"
        >
          <div class="max-w-sm">
            <span class="mx-auto grid size-12 place-items-center rounded-2xl bg-indigo-50 text-indigo-600 dark:bg-indigo-400/10 dark:text-indigo-300">
              <.icon name="hero-queue-list" class="size-6" />
            </span>
            <h2 class="mt-4 text-base font-semibold">Select a workflow to begin</h2>
            <p class="mt-2 text-sm leading-6 text-neutral-500">
              Inspect a built-in template, clone it as a starting point, or create a blank workflow.
            </p>
          </div>
        </section>

        <section :if={is_map(@workflow_template)} id="workflow-editor" class="space-y-5">
          <.form
            for={@workflow_form}
            id="workflow-template-form"
            phx-submit="workflow_save"
            class="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm dark:border-white/10 dark:bg-white/5"
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
                  class="rounded-full bg-indigo-600 px-4 py-2 text-xs font-semibold text-white transition hover:-translate-y-px hover:bg-indigo-500"
                >
                  Clone to edit
                </button>
                <button
                  :if={!built_in?(@workflow_template)}
                  id="workflow-delete"
                  type="button"
                  phx-click="workflow_delete"
                  data-confirm="Delete this workflow template?"
                  class="rounded-full px-3 py-2 text-xs font-semibold text-rose-600 transition hover:bg-rose-50 dark:hover:bg-rose-400/10"
                >
                  Delete
                </button>
                <button
                  :if={!built_in?(@workflow_template)}
                  id="workflow-save"
                  type="submit"
                  class="rounded-full bg-neutral-900 px-4 py-2 text-xs font-semibold text-white transition hover:-translate-y-px hover:bg-indigo-600 dark:bg-white dark:text-neutral-900"
                >
                  Validate & save
                </button>
              </div>
            </div>
          </.form>

          <div
            :if={!built_in?(@workflow_template)}
            id="workflow-preset-palette"
            class="flex flex-wrap items-center gap-2 rounded-2xl border border-neutral-200 bg-white p-3 shadow-sm dark:border-white/10 dark:bg-white/5"
          >
            <span class="mr-1 text-xs font-semibold text-neutral-500">Add stage</span>
            <button
              :for={{label, preset} <- @workflow_presets}
              id={"workflow-add-#{preset}"}
              type="button"
              phx-click="workflow_add_stage"
              phx-value-preset={preset}
              class="rounded-full border border-neutral-200 px-3 py-1.5 text-xs font-medium transition hover:border-indigo-300 hover:bg-indigo-50 hover:text-indigo-700 dark:border-white/10 dark:hover:bg-indigo-400/10 dark:hover:text-indigo-200"
            >
              <.icon name="hero-plus-small" class="mr-1 inline size-3.5" />{label}
            </button>
          </div>

          <div
            id="workflow-stage-list"
            phx-update="stream"
            class="relative space-y-4 before:absolute before:bottom-6 before:left-6 before:top-6 before:w-px before:bg-indigo-200 dark:before:bg-indigo-400/20"
          >
            <div
              id="workflow-stage-empty"
              class="hidden only:block rounded-2xl border border-dashed border-neutral-300 p-10 text-center text-sm text-neutral-500 dark:border-white/15"
            >
              Add the first stage from the preset palette.
            </div>
            <article
              :for={{dom_id, stage} <- @streams.workflow_stages}
              id={dom_id}
              class="relative ml-12 rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm transition hover:border-neutral-300 dark:border-white/10 dark:bg-white/5"
            >
              <span class="absolute -left-[2.15rem] top-6 size-5 rounded-full border-4 border-neutral-50 bg-indigo-500 dark:border-neutral-900">
              </span>
              <.form
                for={stage.form}
                id={"workflow-stage-form-#{stage.id}"}
                phx-change="workflow_update_stage"
                class="space-y-4"
              >
                <input type="hidden" name="stage_id" value={stage.id} />
                <div class="flex items-start gap-3">
                  <div class="min-w-0 flex-1">
                    <.input
                      field={stage.form[:name]}
                      id={"workflow-stage-name-#{stage.id}"}
                      label="Stage name"
                      disabled={built_in?(@workflow_template)}
                    />
                  </div>
                  <div :if={!built_in?(@workflow_template)} class="flex gap-1 pt-7">
                    <button
                      id={"workflow-stage-up-#{stage.id}"}
                      type="button"
                      phx-click="workflow_move_stage"
                      phx-value-id={stage.id}
                      phx-value-direction="up"
                      class="rounded-lg p-2 text-neutral-400 hover:bg-neutral-100 hover:text-neutral-900 dark:hover:bg-white/10"
                    >
                      <.icon name="hero-chevron-up" class="size-4" />
                    </button>
                    <button
                      id={"workflow-stage-down-#{stage.id}"}
                      type="button"
                      phx-click="workflow_move_stage"
                      phx-value-id={stage.id}
                      phx-value-direction="down"
                      class="rounded-lg p-2 text-neutral-400 hover:bg-neutral-100 hover:text-neutral-900 dark:hover:bg-white/10"
                    >
                      <.icon name="hero-chevron-down" class="size-4" />
                    </button>
                    <button
                      id={"workflow-stage-delete-#{stage.id}"}
                      type="button"
                      phx-click="workflow_delete_stage"
                      phx-value-id={stage.id}
                      class="rounded-lg p-2 text-neutral-400 hover:bg-rose-50 hover:text-rose-600 dark:hover:bg-rose-400/10"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </div>
                <.input
                  field={stage.form[:instructions]}
                  id={"workflow-stage-instructions-#{stage.id}"}
                  type="textarea"
                  rows="4"
                  label="Instructions"
                  disabled={built_in?(@workflow_template)}
                />
                <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                  <.input
                    field={stage.form[:profile]}
                    id={"workflow-stage-profile-#{stage.id}"}
                    type="select"
                    label="Profile"
                    options={[{"Coding", "coding"}, {"Inspect only", "inspect"}]}
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={stage.form[:model]}
                    id={"workflow-stage-model-#{stage.id}"}
                    label="Model override"
                    placeholder="Default"
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={stage.form[:effort]}
                    id={"workflow-stage-effort-#{stage.id}"}
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
                    field={stage.form[:attempts]}
                    id={"workflow-stage-attempts-#{stage.id}"}
                    type="number"
                    min="1"
                    max="5"
                    label="Attempts"
                    disabled={built_in?(@workflow_template)}
                  />
                  <.input
                    field={stage.form[:timeout_ms]}
                    id={"workflow-stage-timeout-#{stage.id}"}
                    type="number"
                    min="1000"
                    label="Timeout (ms)"
                    disabled={built_in?(@workflow_template)}
                  />
                  <div class="sm:col-span-2 xl:col-span-3">
                    <.input
                      field={stage.form[:input_artifacts]}
                      id={"workflow-stage-artifacts-#{stage.id}"}
                      label="Input artifacts"
                      placeholder="plan.md, previous.diff"
                      disabled={built_in?(@workflow_template)}
                    />
                  </div>
                </div>
              </.form>
            </article>
          </div>
        </section>
      </div>
    </main>
    """
  end

  defp template_id(template), do: value(template, :id, "")
  defp template_name(template), do: value(template, :name, "Untitled workflow")
  defp template_description(template), do: value(template, :description, "")
  defp built_in?(template), do: value(template, :built_in, false)
  defp selected?(:none, _template), do: false
  defp selected?(selected, template), do: template_id(selected) == template_id(template)
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
