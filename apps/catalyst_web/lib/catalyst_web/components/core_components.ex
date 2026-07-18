defmodule CatalystWeb.CoreComponents do
  @moduledoc """
  Small, application-wide UI primitives styled with Tailwind CSS utilities.

  Form controls and structured data displays live in `CatalystWeb.FormComponents`
  and `CatalystWeb.DataComponents`. Compatibility delegates remain here for code
  that calls the historical module directly; templates receive all three modules
  through `CatalystWeb`'s HTML helpers.
  """

  use Phoenix.Component

  alias CatalystWeb.{DataComponents, FormComponents}
  alias Phoenix.LiveView.JS

  @button_variants %{
    "primary" =>
      "bg-neutral-950 text-white shadow-sm shadow-neutral-950/20 hover:bg-neutral-800 dark:bg-white dark:text-neutral-950 dark:hover:bg-neutral-200",
    "secondary" =>
      "border border-neutral-200 bg-white text-neutral-700 shadow-sm hover:border-neutral-300 hover:bg-neutral-50 dark:border-white/10 dark:bg-white/10 dark:text-neutral-100 dark:hover:bg-white/15",
    "danger" =>
      "bg-rose-600 text-white shadow-sm shadow-rose-900/20 hover:bg-rose-500 dark:bg-rose-500 dark:hover:bg-rose-400",
    "ghost" =>
      "text-neutral-600 hover:bg-neutral-100 hover:text-neutral-950 dark:text-neutral-300 dark:hover:bg-white/10 dark:hover:text-white",
    nil =>
      "bg-neutral-950 text-white shadow-sm shadow-neutral-950/20 hover:bg-neutral-800 dark:bg-white dark:text-neutral-950 dark:hover:bg-neutral-200"
  }

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
        "rounded-2xl border px-4 py-3 text-sm shadow-xl backdrop-blur transition",
        @kind == :info &&
          "border-sky-200 bg-sky-50/95 text-sky-950 shadow-sky-900/10 dark:border-sky-400/20 dark:bg-sky-950/90 dark:text-sky-100",
        @kind == :error &&
          "border-rose-200 bg-rose-50/95 text-rose-950 shadow-rose-900/10 dark:border-rose-400/20 dark:bg-rose-950/90 dark:text-rose-100"
      ]}
      {@rest}
    >
      <div class="flex items-start gap-3">
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="mt-0.5 size-5 shrink-0 text-sky-500"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle"
          class="mt-0.5 size-5 shrink-0 text-rose-500"
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

  @doc "Renders a button or navigation link with a consistent visual variant."
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type title id phx-click)

  attr :class, :any
  attr :variant, :string, values: ~w(primary secondary danger ghost)
  slot :inner_block, required: true

  @spec button(map()) :: Phoenix.LiveView.Rendered.t()
  def button(%{rest: rest} = assigns) do
    classes =
      Map.get(assigns, :class) ||
        [
          "inline-flex items-center justify-center gap-2 rounded-full px-4 py-2 text-sm font-semibold transition focus:outline-none focus:ring-2 focus:ring-neutral-400 focus:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 dark:focus:ring-white/40 dark:focus:ring-offset-neutral-900",
          Map.fetch!(@button_variants, Map.get(assigns, :variant))
        ]

    assigns = assign(assigns, :class, classes)

    case navigation?(rest) do
      true ->
        ~H"""
        <.link class={@class} {@rest}>
          {render_slot(@inner_block)}
        </.link>
        """

      false ->
        ~H"""
        <button class={@class} {@rest}>
          {render_slot(@inner_block)}
        </button>
        """
    end
  end

  @doc "Renders a section header with optional subtitle and actions."
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-neutral-950 dark:text-white">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-neutral-500 dark:text-neutral-400">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
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

  @doc "Builds a LiveView JS command that reveals the target with a transition."
  @spec show(String.t()) :: JS.t()
  def show(selector), do: JS.show(show_options(selector))

  @doc "Adds the reveal transition to an existing LiveView JS command."
  @spec show(JS.t(), String.t()) :: JS.t()
  def show(js, selector), do: JS.show(js, show_options(selector))

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
  @spec table(map()) :: Phoenix.LiveView.Rendered.t()
  defdelegate table(assigns), to: DataComponents

  @doc false
  @spec list(map()) :: Phoenix.LiveView.Rendered.t()
  defdelegate list(assigns), to: DataComponents

  @doc false
  @spec translate_error({String.t(), keyword()}) :: String.t()
  defdelegate translate_error(error), to: FormComponents

  @doc false
  @spec translate_errors(keyword(), atom()) :: [String.t()]
  defdelegate translate_errors(errors, field), to: FormComponents

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

  defp navigation?(attributes) do
    Enum.any?([:href, :navigate, :patch], &Map.get(attributes, &1))
  end
end
