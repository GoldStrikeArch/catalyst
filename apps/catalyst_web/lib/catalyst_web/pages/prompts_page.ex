defmodule CatalystWeb.Pages.PromptsPage do
  @moduledoc """
  Built-in editor for the file-backed system-prompt layers.

  The page writes only paths already read by `Catalyst.SystemPrompt`. Runtime
  extensions, application configuration, and session overrides retain their
  documented higher precedence.
  """

  use CatalystWeb, :html

  alias Catalyst.Prompt.Store
  alias Catalyst.SystemPrompt

  @doc "Builds the prompt-file rows shown for the current Codex catalog."
  @spec panel_data([map()]) :: [map()]
  def panel_data(catalog) do
    [
      row(:default, "Default system prompt", "Fallback for every model"),
      row(
        {:api, "openai-codex-responses"},
        "All Codex models",
        "Used when a model-specific file is absent"
      )
      | model_rows(catalog)
    ] ++
      [row(:append, "Append to every system prompt", "Added after whichever system base wins")]
  end

  @doc "Renders the prompt editor."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <main id="prompts-page" class="flex-1 overflow-y-auto px-4 py-6 sm:px-6">
      <div class="mx-auto flex max-w-5xl flex-col gap-5">
        <header class="rounded-2xl border border-neutral-200 bg-white px-5 py-4 shadow-sm dark:border-white/10 dark:bg-white/5">
          <div class="flex items-start gap-3">
            <span class="rounded-xl bg-indigo-50 p-2 text-indigo-600 dark:bg-indigo-400/10 dark:text-indigo-300">
              <.icon name="hero-document-text" class="size-5" />
            </span>
            <div>
              <h1 class="text-base font-semibold text-neutral-950 dark:text-white">
                Models & Prompts
              </h1>
              <p class="mt-1 max-w-3xl text-sm leading-6 text-neutral-500 dark:text-neutral-400">
                Edit Catalyst's durable file-backed prompt layer. Saved changes apply to the next
                run. Session overrides, extensions, and application configuration remain higher
                priority and are visible in Run diagnostics.
              </p>
            </div>
          </div>
        </header>

        <section
          :if={match?({:ok, _}, @prompt_preview)}
          id="effective-prompt-preview"
          class="rounded-2xl border border-neutral-200 bg-white px-5 py-4 shadow-sm dark:border-white/10 dark:bg-white/5"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-sm font-semibold text-neutral-900 dark:text-white">
              Effective selected-model prompt
            </h2>
            <code class="font-mono text-[0.65rem] text-neutral-400">
              {digest_prefix(elem(@prompt_preview, 1).digest)}
            </code>
          </div>
          <p class="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
            {elem(@prompt_preview, 1).model_id || "default"} · {source_summary(
              elem(@prompt_preview, 1).sources
            )}
          </p>
        </section>

        <section id="prompt-rows" phx-update="stream" class="grid gap-4">
          <article
            :for={{id, row} <- @streams.prompt_rows}
            id={id}
            class={[
              "rounded-2xl border bg-white shadow-sm transition dark:bg-white/5",
              row.error &&
                "border-rose-300 dark:border-rose-400/30",
              !row.error &&
                "border-neutral-200 hover:border-neutral-300 dark:border-white/10 dark:hover:border-white/20"
            ]}
          >
            <div class="flex flex-wrap items-start gap-3 border-b border-neutral-200/70 px-5 py-3 dark:border-white/10">
              <div class="min-w-0 flex-1">
                <h2 class="text-sm font-semibold text-neutral-900 dark:text-white">{row.label}</h2>
                <p class="mt-0.5 text-xs text-neutral-500 dark:text-neutral-400">
                  {row.description}
                </p>
                <p class="mt-1 truncate font-mono text-[0.65rem] text-neutral-400 dark:text-neutral-500">
                  {row.path}
                </p>
              </div>
              <span class={[
                "rounded-full px-2 py-0.5 text-[0.65rem] font-medium",
                row.saved? &&
                  "bg-emerald-50 text-emerald-700 dark:bg-emerald-400/10 dark:text-emerald-200",
                !row.saved? &&
                  "bg-neutral-100 text-neutral-500 dark:bg-white/10 dark:text-neutral-400"
              ]}>
                {if(row.saved?, do: "custom", else: "inherited")}
              </span>
            </div>

            <div class="px-5 py-4">
              <p :if={row.error} class="mb-3 text-xs text-rose-600 dark:text-rose-300">
                Could not read this prompt: {inspect(row.error)}
              </p>

              <.form
                for={row.form}
                id={"prompt-form-#{row.dom_id}"}
                phx-submit="save_prompt"
                class="space-y-3"
              >
                <.input
                  field={row.form[:target]}
                  id={"prompt-target-#{row.dom_id}"}
                  type="hidden"
                  container_class="hidden"
                />
                <.input
                  field={row.form[:text]}
                  id={"prompt-text-#{row.dom_id}"}
                  type="textarea"
                  rows="9"
                  maxlength={64 * 1024}
                  placeholder="Enter a prompt to create this layer…"
                  container_class="m-0"
                  class="min-h-44 w-full resize-y rounded-xl border border-neutral-200 bg-neutral-50 px-3 py-2.5 font-mono text-xs leading-5 text-neutral-800 shadow-inner outline-none transition placeholder:text-neutral-400 focus:border-indigo-400 focus:ring-2 focus:ring-indigo-400/20 dark:border-white/10 dark:bg-neutral-950/40 dark:text-neutral-200 dark:placeholder:text-neutral-600"
                />
                <div class="flex items-center justify-end gap-2">
                  <button
                    :if={row.saved?}
                    id={"prompt-reset-#{row.dom_id}"}
                    type="button"
                    phx-click="delete_prompt"
                    phx-value-target={row.target}
                    data-confirm="Delete this prompt file and restore inherited behavior?"
                    class="rounded-full px-3 py-1.5 text-xs font-medium text-neutral-500 transition hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-white/10 dark:hover:text-white"
                  >
                    Reset
                  </button>
                  <button
                    id={"prompt-save-#{row.dom_id}"}
                    type="submit"
                    class="rounded-full bg-neutral-900 px-3.5 py-1.5 text-xs font-semibold text-white shadow-sm transition hover:-translate-y-px hover:bg-neutral-700 dark:bg-white dark:text-neutral-900 dark:hover:bg-neutral-200"
                  >
                    Save
                  </button>
                </div>
              </.form>
            </div>
          </article>
        </section>
      </div>
    </main>
    """
  end

  defp model_rows(catalog) do
    catalog
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(fn model ->
      row({:model, model.id}, model.name, model.id)
    end)
  end

  defp row(target, label, description) do
    encoded = encode_target(target)
    {:ok, path} = Store.path(target)

    {text, saved?, error} =
      case Store.read(target) do
        {:ok, text} -> {text, true, nil}
        :missing -> {"", false, nil}
        {:error, reason} -> {"", false, reason}
      end

    %{
      id: "prompt-row-#{dom_id(target)}",
      target: encoded,
      dom_id: dom_id(target),
      label: label,
      description: description,
      path: path,
      saved?: saved?,
      error: error,
      form: to_form(%{"target" => encoded, "text" => text})
    }
  end

  defp encode_target(:default), do: "default"
  defp encode_target(:append), do: "append"
  defp encode_target({:api, key}), do: "api:" <> key
  defp encode_target({:model, key}), do: "model:" <> key

  defp dom_id(:default), do: "default"
  defp dom_id(:append), do: "append"

  defp dom_id({kind, key}) do
    slug = SystemPrompt.slug(key)

    case slug == key do
      true -> "#{kind}-#{slug}"
      false -> "#{kind}-#{slug}-#{key_digest(key)}"
    end
  end

  defp key_digest(key) do
    key
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end

  defp digest_prefix(digest) when is_binary(digest), do: String.slice(digest, 0, 12)
  defp digest_prefix(_digest), do: "—"

  defp source_summary(sources) do
    sources
    |> Enum.map(&inspect/1)
    |> Enum.join(" → ")
  end
end
