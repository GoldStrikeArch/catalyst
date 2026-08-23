defmodule CatalystWeb.Workbench.ChatView do
  @moduledoc "Function-component render target for the built-in chat workbench."

  use CatalystWeb, :html

  alias CatalystWeb.UI.Markdown

  @doc "Render chat from host-owned forms and serializable Workbench state."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div
      id="chat-workbench"
      data-session-id={@workbench_state.session_id}
      class="flex h-screen min-h-[36rem] flex-col overflow-hidden bg-bg text-ink"
    >
      <header class="flex h-14 shrink-0 items-center gap-3 border-b border-edge bg-surface/95 px-4 backdrop-blur">
        <div class="flex min-w-0 items-center gap-2.5">
          <div class="flex size-8 items-center justify-center rounded-lg bg-accent/10 text-accent">
            <.icon name="hero-sparkles" class="size-4.5" />
          </div>
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <h1 class="text-sm font-semibold tracking-tight">Catalyst Agent</h1>
              <span
                id="workbench-chat-status"
                data-status={@workbench_state.status}
                class={[
                  "rounded-full px-2 py-0.5 text-[9px] font-semibold uppercase tracking-[0.14em]",
                  @workbench_state.status == :ready && "bg-success/10 text-success",
                  @workbench_state.status == :starting && "bg-warning/10 text-warning",
                  @workbench_state.status == :error && "bg-danger/10 text-danger"
                ]}
              >
                {@workbench_state.status}
              </span>
            </div>
            <p class="max-w-72 truncate font-mono text-[9px] text-faint">
              {@workbench_state.workspace}
            </p>
          </div>
        </div>

        <.form
          for={@workbench_forms.model}
          id="workbench-model-form"
          phx-change="workbench:chat:model"
          class="ml-auto w-52"
        >
          <.input
            field={@workbench_forms.model[:selection]}
            type="select"
            id="workbench-model-select"
            options={model_options(@workbench_state.models)}
            container_class="m-0"
            class="h-8 w-full rounded-lg border border-edge bg-raised px-2 text-xs text-ink outline-none transition focus:border-accent/50 focus:ring-2 focus:ring-accent/10"
          />
        </.form>

        <button
          :if={auth_action(@workbench_state) == :login}
          id="workbench-auth-login"
          type="button"
          phx-click="workbench:chat:login"
          class="inline-flex items-center gap-1.5 rounded-lg border border-edge bg-raised px-2.5 py-1.5 text-xs font-medium text-muted transition hover:border-edge-strong hover:text-ink"
        >
          <.icon name="hero-arrow-right-end-on-rectangle" class="size-3.5" /> Sign in
        </button>
        <button
          :if={auth_action(@workbench_state) == :logout}
          id="workbench-auth-logout"
          type="button"
          phx-click="workbench:chat:logout"
          class="inline-flex items-center gap-1.5 rounded-lg border border-success/30 bg-success/10 px-2.5 py-1.5 text-xs font-medium text-success transition hover:brightness-110"
        >
          <.icon name="hero-check-circle" class="size-3.5" /> Signed in
        </button>

        <details id="workbench-chat-controls" class="group relative">
          <summary class="inline-flex cursor-pointer list-none items-center gap-1.5 rounded-lg border border-edge bg-raised px-2.5 py-1.5 text-xs font-medium text-muted transition hover:border-edge-strong hover:text-ink">
            <.icon name="hero-adjustments-horizontal" class="size-3.5" /> Controls
          </summary>
          <div class="absolute right-0 top-10 z-40 w-72 rounded-xl border border-edge bg-surface p-4 shadow-2xl">
            <.form
              for={@workbench_forms.controls}
              id="workbench-controls-form"
              phx-change="workbench:chat:controls"
              class="space-y-3"
            >
              <.input
                field={@workbench_forms.controls[:effort]}
                type="select"
                id="workbench-effort-select"
                label="Reasoning effort"
                options={effort_options(@workbench_state)}
              />
              <.input
                field={@workbench_forms.controls[:transport]}
                type="select"
                id="workbench-transport-select"
                label="Transport"
                options={transport_options(@workbench_state)}
              />
              <.input
                field={@workbench_forms.controls[:workflow]}
                type="select"
                id="workbench-workflow-select"
                label="Workflow"
                options={workflow_options(@workbench_state.workflows)}
              />
            </.form>
            <div class="mt-4 grid grid-cols-3 gap-2">
              <.control_toggle
                id="workbench-fast-toggle"
                event="workbench:chat:toggle-fast"
                active={@workbench_state.settings.fast}
                label="Fast"
                icon="hero-bolt"
              />
              <.control_toggle
                id="workbench-quiet-toggle"
                event="workbench:chat:toggle-quiet"
                active={@workbench_state.settings.quiet}
                label="Quiet"
                icon="hero-eye-slash"
              />
              <.control_toggle
                id="workbench-computer-toggle"
                event="workbench:chat:toggle-computer"
                active={@workbench_state.settings.computer_use}
                label="Computer"
                icon="hero-computer-desktop"
              />
            </div>
          </div>
        </details>

        <button
          id="workbench-chat-new"
          type="button"
          phx-click="workbench:chat:new"
          class="inline-flex items-center gap-1.5 rounded-lg border border-edge bg-raised px-2.5 py-1.5 text-xs font-medium text-muted transition hover:border-edge-strong hover:text-ink"
        >
          <.icon name="hero-plus" class="size-3.5" /> New
        </button>
        <button
          id="workbench-chat-apply-active"
          type="button"
          phx-click="workbench:host:remount"
          class="inline-flex items-center gap-1.5 rounded-lg border border-edge bg-raised px-2.5 py-1.5 text-xs font-medium text-muted transition hover:border-edge-strong hover:text-ink"
        >
          <.icon name="hero-arrow-path-rounded-square" class="size-3.5" /> Apply active
        </button>
        <.link
          id="workbench-chat-ide-link"
          navigate={~p"/ide"}
          class="inline-flex items-center gap-1.5 rounded-lg bg-accent px-2.5 py-1.5 text-xs font-semibold text-white shadow-sm transition hover:brightness-110"
        >
          <.icon name="hero-code-bracket-square" class="size-3.5" /> IDE
        </.link>
        <details id="workbench-product-navigation" class="group relative">
          <summary class="flex size-8 cursor-pointer list-none items-center justify-center rounded-lg text-muted transition hover:bg-raised hover:text-ink">
            <.icon name="hero-ellipsis-horizontal" class="size-4" />
          </summary>
          <nav class="absolute right-0 top-10 z-40 w-48 rounded-xl border border-edge bg-surface p-2 shadow-2xl">
            <.nav_link id="workbench-nav-extensions" path={~p"/extensions"} label="Extensions" />
            <.nav_link id="workbench-nav-workflows" path={~p"/workflows"} label="Workflows" />
            <.nav_link id="workbench-nav-prompts" path={~p"/prompts"} label="Prompts" />
            <.nav_link id="workbench-nav-compare" path={~p"/compare"} label="Comparison" />
            <.nav_link id="workbench-nav-legacy" path={~p"/legacy-chat"} label="Legacy chat" />
          </nav>
        </details>
      </header>

      <div class="flex min-h-0 flex-1">
        <aside
          id="workbench-thread-sidebar"
          class="flex w-56 shrink-0 flex-col overflow-y-auto border-r border-edge bg-surface/70"
        >
          <div class="flex h-10 shrink-0 items-center justify-between border-b border-edge px-3">
            <span class="text-[10px] font-semibold uppercase tracking-[0.16em] text-faint">
              Projects & threads
            </span>
            <button
              type="button"
              phx-click="workbench:chat:new"
              class="rounded p-1 text-faint transition hover:bg-raised hover:text-ink"
              aria-label="New thread"
            >
              <.icon name="hero-plus" class="size-3.5" />
            </button>
          </div>

          <p
            :if={@workbench_state.threads.projects == []}
            id="workbench-threads-empty"
            class="px-4 py-6 text-xs text-faint"
          >
            No saved threads yet.
          </p>

          <section
            :for={project <- @workbench_state.threads.projects}
            id={project.id}
            class="border-b border-edge/70 px-2 py-2"
          >
            <div class="flex items-center gap-1.5 px-2 py-1">
              <.icon name="hero-folder" class="size-3.5 shrink-0 text-faint" />
              <span class="truncate text-[11px] font-semibold text-muted">{project.label}</span>
            </div>
            <div class="mt-1 space-y-0.5">
              <div
                :for={thread <- project.threads}
                id={"workbench-thread-#{thread.id}"}
                data-current={to_string(thread.current?)}
                data-thread-id={thread.id}
                class={[
                  "group flex items-center gap-1 rounded-lg",
                  thread.current? && "bg-raised"
                ]}
              >
                <button
                  id={"workbench-switch-thread-#{thread.id}"}
                  type="button"
                  phx-click="workbench:chat:switch"
                  phx-value-id={thread.id}
                  class={[
                    "flex min-w-0 flex-1 items-center gap-2 rounded-lg px-2 py-1.5 text-left text-[11px] transition",
                    thread.current? && "text-ink",
                    !thread.current? && "text-muted hover:bg-raised hover:text-ink"
                  ]}
                >
                  <span class={[
                    "size-1.5 shrink-0 rounded-full",
                    thread.live? && "bg-success",
                    !thread.live? && "bg-edge-strong"
                  ]}></span>
                  <span class="truncate">{thread.title}</span>
                </button>
                <button
                  id={"workbench-close-thread-#{thread.id}"}
                  type="button"
                  phx-click="workbench:chat:close"
                  phx-value-id={thread.id}
                  class="mr-1 rounded p-1 text-faint opacity-0 transition hover:bg-bg hover:text-danger group-hover:opacity-100"
                  aria-label="Close thread"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
            </div>
          </section>
        </aside>

        <div class="flex min-w-0 flex-1 flex-col">
          <main class="min-h-0 flex-1 overflow-y-auto">
            <div class="mx-auto flex min-h-full w-full max-w-4xl flex-col px-6 py-8">
              <div
                :if={@workbench_state.messages == []}
                id="workbench-chat-empty"
                class="flex flex-1 flex-col items-center justify-center py-16 text-center"
              >
                <div class="flex size-14 items-center justify-center rounded-2xl border border-accent/20 bg-accent/10 text-accent shadow-sm">
                  <.icon name="hero-chat-bubble-left-right" class="size-7" />
                </div>
                <h2 class="mt-5 text-lg font-semibold tracking-tight">What should we build?</h2>
                <p class="mt-2 max-w-md text-sm leading-6 text-muted">
                  Chat, models, threads, files, and images are mediated through bounded Workbench
                  host effects.
                </p>
              </div>

              <p
                :if={@workbench_state.messages_truncated > 0}
                id="workbench-transcript-truncated"
                class="mb-5 rounded-lg border border-warning/20 bg-warning/5 px-3 py-2 text-xs text-warning"
              >
                {@workbench_state.messages_truncated} older transcript messages are hidden from
                this live projection and remain available in the session transcript.
              </p>

              <div id="workbench-chat-messages" class="space-y-5">
                <.projected_message
                  :for={message <- visible_messages(@workbench_state)}
                  message={message}
                  quiet={@workbench_state.settings.quiet}
                />
              </div>
              <article
                id="workbench-streaming-preview"
                phx-hook="StreamingMessage"
                phx-update="ignore"
                hidden
                class="mt-5 flex gap-3"
              >
                <div class="mt-1 flex size-8 shrink-0 items-center justify-center rounded-lg border border-edge bg-surface text-accent">
                  <.icon name="hero-sparkles" class="size-4" />
                </div>
                <div class="w-full max-w-[86%] rounded-2xl rounded-tl-sm border border-edge bg-surface px-4 py-3 shadow-sm">
                  <p
                    data-stream="thinking"
                    class="mb-2 whitespace-pre-wrap text-xs italic leading-5 text-muted"
                  >
                  </p>
                  <p data-stream="text" class="whitespace-pre-wrap text-sm leading-6"></p>
                  <span data-stream-dots class="text-sm text-faint">Thinking…</span>
                </div>
              </article>
            </div>
          </main>

          <footer class="shrink-0 border-t border-edge bg-surface/95 px-5 py-4 backdrop-blur">
            <div class="relative mx-auto w-full max-w-4xl">
              <p
                :if={@workbench_state.error}
                id="workbench-chat-error"
                class="mb-3 rounded-lg border border-danger/20 bg-danger/5 px-3 py-2 text-xs text-danger"
              >
                {@workbench_state.error}
              </p>

              <div
                :if={@workbench_state.file_search}
                id="workbench-file-search"
                class="absolute inset-x-0 bottom-full z-20 mb-2 rounded-xl border border-edge bg-surface p-2 shadow-xl"
              >
                <p class="px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.14em] text-faint">
                  Files matching “@{@workbench_state.file_search.query}”
                </p>
                <button
                  :for={result <- @workbench_state.file_search.results}
                  type="button"
                  phx-click="workbench:chat:pick-file"
                  phx-value-label={result.label}
                  phx-value-path={result.path}
                  class="flex w-full items-center gap-3 rounded-lg px-2 py-1.5 text-left text-xs transition hover:bg-raised"
                >
                  <code class="shrink-0 font-semibold text-ink">{result.label}</code>
                  <span class="truncate font-mono text-faint">{result.path}</span>
                </button>
              </div>

              <.form
                for={@workbench_forms.chat}
                id="workbench-chat-form"
                phx-change="workbench:chat:change"
                phx-submit="workbench:chat:submit"
                phx-hook="PasteImages"
                class="rounded-2xl border border-edge bg-bg p-2 shadow-sm transition focus-within:border-accent/50 focus-within:ring-4 focus-within:ring-accent/5"
              >
                <div
                  :if={@uploads.image.entries != []}
                  id="workbench-image-uploads"
                  class="mb-2 flex flex-wrap items-center gap-2 px-2 pt-1"
                >
                  <div
                    :for={entry <- @uploads.image.entries}
                    id={"workbench-image-#{entry.ref}"}
                    class="relative"
                  >
                    <.live_img_preview
                      entry={entry}
                      class="size-16 rounded-lg border border-edge object-cover"
                    />
                    <button
                      type="button"
                      phx-click="workbench:host:cancel-image"
                      phx-value-ref={entry.ref}
                      class="absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full border border-edge bg-surface text-muted shadow transition hover:text-danger"
                      aria-label="Remove image"
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                    <span
                      :if={not entry.done?}
                      class="absolute inset-x-0 bottom-0 rounded-b-lg bg-surface/85 text-center text-[9px]"
                    >
                      {entry.progress}%
                    </span>
                  </div>
                </div>

                <div class="flex items-end gap-3">
                  <.input
                    field={@workbench_forms.chat[:message]}
                    type="textarea"
                    id="workbench-chat-input"
                    rows="2"
                    autocomplete="off"
                    phx-debounce="150"
                    phx-hook="ChatSubmit"
                    container_class="min-w-0 flex-1"
                    class="max-h-40 min-h-12 w-full resize-none border-0 bg-transparent px-3 py-3 text-sm leading-6 text-ink outline-none placeholder:text-faint focus:ring-0"
                    placeholder="Ask Catalyst… Use @ to reference files or paste an image."
                  />
                  <.live_file_input
                    id="workbench-image-input"
                    upload={@uploads.image}
                    class="hidden"
                  />
                  <button
                    :if={@workbench_state.running}
                    id="workbench-chat-abort"
                    type="button"
                    phx-click="workbench:chat:abort"
                    class="mb-1 flex size-10 shrink-0 items-center justify-center rounded-xl bg-danger text-white shadow-sm transition hover:brightness-110"
                    aria-label="Stop the current run"
                  >
                    <.icon name="hero-stop" class="size-5" />
                  </button>
                  <button
                    :if={not @workbench_state.running}
                    id="workbench-chat-submit"
                    type="submit"
                    disabled={@workbench_state.status != :ready}
                    class="mb-1 flex size-10 shrink-0 items-center justify-center rounded-xl bg-accent text-white shadow-sm transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-40"
                    aria-label="Send message"
                  >
                    <.icon name="hero-arrow-up" class="size-5" />
                  </button>
                </div>
              </.form>
              <p class="mt-2 text-center text-[10px] text-faint">
                Session {@workbench_state.session_id || "starting"} · mount-pinned workbench
              </p>
            </div>
          </footer>
        </div>
      </div>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :quiet, :boolean, required: true

  defp projected_message(assigns) do
    ~H"""
    <article
      id={@message.id}
      data-role={@message.role}
      class={[
        "group flex gap-3",
        @message.role == "user" && "flex-row-reverse"
      ]}
    >
      <div class={[
        "mt-1 flex size-8 shrink-0 items-center justify-center rounded-lg",
        @message.role == "user" && "bg-accent text-white",
        @message.role == "assistant" && "border border-edge bg-surface text-accent",
        @message.role == "tool" && "border border-edge bg-raised text-muted"
      ]}>
        <.icon name={message_icon(@message.role)} class="size-4" />
      </div>
      <div class={[
        "max-w-[86%] rounded-2xl px-4 py-3 shadow-sm",
        @message.role == "user" && "rounded-tr-sm bg-accent text-white",
        @message.role == "assistant" && "w-full rounded-tl-sm border border-edge bg-surface",
        @message.role == "tool" && "w-full rounded-tl-sm border border-edge bg-raised"
      ]}>
        <p
          :if={@message.role == "tool" && @message[:tool_name]}
          class="mb-2 text-xs font-semibold text-muted"
        >
          {@message.tool_name}
        </p>
        <.projected_block
          :for={block <- visible_blocks(@message.blocks, @quiet)}
          block={block}
          user?={@message.role == "user"}
        />
        <p :if={@message.blocks == []} class="whitespace-pre-wrap text-sm leading-6">
          {visible_text(@message.text)}
        </p>
        <p :if={@message.error} class="mt-2 text-xs text-danger">{@message.error}</p>
      </div>
    </article>
    """
  end

  attr :block, :map, required: true
  attr :user?, :boolean, default: false

  defp projected_block(%{block: %{type: "text"}, user?: true} = assigns) do
    ~H"""
    <p class="whitespace-pre-wrap text-sm leading-6">{@block.text}</p>
    """
  end

  defp projected_block(%{block: %{type: "text"}} = assigns) do
    assigns = assign(assigns, :markdown, Markdown.parse(assigns.block.text))

    ~H"""
    <div class="space-y-2 text-sm leading-7">
      <%= for block <- @markdown do %>
        {CatalystWeb.UI.MessageRenderer.markdown_block(%{block: block})}
      <% end %>
    </div>
    """
  end

  defp projected_block(%{block: %{type: "thinking"}} = assigns) do
    ~H"""
    <details class="group my-1">
      <summary class="flex cursor-pointer list-none items-center gap-1.5 text-xs text-faint hover:text-muted">
        <.icon
          name="hero-chevron-right-micro"
          class="size-3 transition-transform group-open:rotate-90"
        /> Thinking
      </summary>
      <div class="mt-1 whitespace-pre-wrap border-l border-edge pl-3 text-xs leading-5 text-faint">
        {@block.text}
      </div>
    </details>
    """
  end

  defp projected_block(%{block: %{type: "tool_call"}} = assigns) do
    assigns =
      assign(assigns, :arguments, inspect(assigns.block.arguments, pretty: true, limit: 50))

    ~H"""
    <details class="group my-1">
      <summary class="cursor-pointer text-xs font-medium text-muted hover:text-ink">
        {@block.name}
      </summary>
      <pre class="mt-1 max-h-60 overflow-auto whitespace-pre-wrap rounded-lg bg-raised p-2 font-mono text-[11px] text-muted">{@arguments}</pre>
    </details>
    """
  end

  defp projected_block(%{block: %{type: "image", src: src}} = assigns)
       when is_binary(src) do
    ~H"""
    <img src={@block.src} alt="attached image" class="my-2 max-h-72 max-w-full rounded-xl" />
    """
  end

  defp projected_block(assigns), do: ~H""

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp control_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      aria-pressed={to_string(@active)}
      class={[
        "flex flex-col items-center gap-1 rounded-lg border px-2 py-2 text-[10px] font-semibold transition",
        @active && "border-accent/30 bg-accent/10 text-accent",
        !@active && "border-edge bg-raised text-muted hover:text-ink"
      ]}
    >
      <.icon name={@icon} class="size-4" /> {@label}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@path}
      class="block rounded-lg px-3 py-2 text-xs font-medium text-muted transition hover:bg-raised hover:text-ink"
    >
      {@label}
    </.link>
    """
  end

  defp model_options(models) do
    Enum.map(models, fn model ->
      label = "#{model.provider_name} · #{model.name}"
      {label, "#{model.provider}::#{model.id}"}
    end)
  end

  defp selected_model_entry(state) do
    Enum.find(
      state.models,
      &(&1.provider == state.settings.provider and &1.id == state.settings.model)
    )
  end

  defp auth_action(state) do
    case selected_model_entry(state) do
      %{auth_provider: provider, logged_in: false} when is_binary(provider) -> :login
      %{auth_provider: provider, logged_in: true} when is_binary(provider) -> :logout
      _no_auth -> nil
    end
  end

  defp effort_options(state) do
    case selected_model_entry(state) do
      %{efforts: efforts} -> Enum.map(efforts, &{String.capitalize(&1), &1})
      _missing -> []
    end
  end

  defp transport_options(state) do
    case selected_model_entry(state) do
      %{transports: transports} when transports != [] ->
        Enum.map(transports, &{String.upcase(&1), &1})

      _missing_or_unsupported ->
        [{"Automatic", "auto"}]
    end
  end

  defp workflow_options(workflows),
    do: [{"Default workflow", ""} | Enum.map(workflows, &{&1.label, &1.id})]

  defp visible_messages(state) do
    case state.settings.quiet do
      true -> Enum.reject(state.messages, &(&1.role == "tool"))
      false -> state.messages
    end
  end

  defp visible_blocks(blocks, true), do: Enum.reject(blocks, &(&1.type == "thinking"))
  defp visible_blocks(blocks, false), do: blocks

  defp message_icon("user"), do: "hero-user"
  defp message_icon("tool"), do: "hero-wrench-screwdriver"
  defp message_icon(_assistant), do: "hero-sparkles"

  defp visible_text(""), do: "(structured content)"
  defp visible_text(text), do: text
end
