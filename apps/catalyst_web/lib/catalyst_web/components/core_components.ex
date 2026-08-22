defmodule CatalystWeb.CoreComponents do
  @moduledoc """
  Small, application-wide UI primitives styled with Tailwind CSS utilities.

  Form controls live in `CatalystWeb.FormComponents`. Compatibility delegates
  remain here for code that calls the historical module directly; templates
  receive both modules through `CatalystWeb`'s HTML helpers.
  """

  use Phoenix.Component

  alias CatalystWeb.FormComponents
  alias Phoenix.LiveView.JS

  @doc "Renders a dismissible flash notice."
  attr :id, :string, doc: "the optional id of the flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "arbitrary HTML attributes added to the flash container"

  slot :inner_block, doc: "optional content that replaces the message from the flash map"

  @spec flash(map()) :: Phoenix.LiveView.Rendered.t()
  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={message = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "rounded-lg border px-4 py-3 text-sm shadow-lg backdrop-blur transition",
        @kind == :info && "border-edge bg-surface text-ink",
        @kind == :error && "border-danger/40 bg-surface text-danger"
      ]}
      {@rest}
    >
      <div class="flex items-start gap-3">
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="mt-0.5 size-5 shrink-0 text-accent"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="mt-0.5 size-5 shrink-0 text-danger"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="leading-6">{message}</p>
        </div>
        <button
          type="button"
          class="rounded-full p-1 text-current/45 transition hover:bg-black/5 hover:text-current dark:hover:bg-white/10"
          aria-label="close"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc "Renders a Heroicon from the generated CSS icon set."
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: "hero-" <> _icon} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  # LiveView 1.2.10 makes JS.t/0 opaque. Dialyzer still infers the concrete
  # non-empty ops list returned by the public JS builders and reports that
  # success type as a contract violation, even though these wrappers return
  # the upstream type exactly. Keep the public contracts and suppress only
  # that upstream opaque-type mismatch.
  @dialyzer {:nowarn_function, show: 1}
  @dialyzer {:nowarn_function, hide: 1}
  @dialyzer {:nowarn_function, hide: 2}

  @doc "Builds a LiveView JS command that reveals the target with a transition."
  @spec show(String.t()) :: JS.t()
  def show(selector), do: JS.show(show_options(selector))

  @doc "Builds a LiveView JS command that hides the target with a transition."
  @spec hide(String.t()) :: JS.t()
  def hide(selector), do: JS.hide(hide_options(selector))

  @doc "Adds the hide transition to an existing LiveView JS command."
  @spec hide(JS.t(), String.t()) :: JS.t()
  def hide(js, selector), do: JS.hide(js, hide_options(selector))

  # Compatibility for extensions or application code that call the former
  # CoreComponents functions remotely. HTML helpers import the owning modules,
  # so new templates still receive compile-time attr and slot validation.

  @doc false
  @spec input(map()) :: Phoenix.LiveView.Rendered.t()
  defdelegate input(assigns), to: FormComponents

  @doc false
  @spec translate_error({String.t(), keyword()}) :: String.t()
  defdelegate translate_error(error), to: FormComponents

  defp show_options(selector) do
    [
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    ]
  end

  defp hide_options(selector) do
    [
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    ]
  end
end
