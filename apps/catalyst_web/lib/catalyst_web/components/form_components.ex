defmodule CatalystWeb.FormComponents do
  @moduledoc """
  Form controls and validation-error helpers shared by Catalyst web interfaces.
  """

  use Phoenix.Component

  alias CatalystWeb.CoreComponents

  @doc "Renders an input with an optional label and validation errors."
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(color date datetime-local email file month number password
               hidden search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options passed to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "classes that fully replace the input defaults"
  attr :error_class, :any, default: nil, doc: "classes that replace the error-state defaults"
  attr :container_class, :any, default: "mb-3", doc: "classes for the outer field container"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step title)

  @spec input(map()) :: Phoenix.LiveView.Rendered.t()
  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors =
      case Phoenix.Component.used_input?(field) do
        true -> field.errors
        false -> []
      end

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> field_name(field, assigns.multiple) end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={@container_class}>
      <label for={@id} class="block">
        <span
          :if={@label}
          class="mb-1 block text-sm font-medium text-muted"
        >
          {@label}
        </span>
        <select
          id={@id}
          name={@name}
          class={[
            @class || select_class(),
            @errors != [] && (@error_class || invalid_class())
          ]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={@container_class}>
      <label for={@id} class="block">
        <span
          :if={@label}
          class="mb-1 block text-sm font-medium text-muted"
        >
          {@label}
        </span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || text_input_class(),
            @errors != [] && (@error_class || invalid_class())
          ]}
          {@rest}
        >{@value}</textarea>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={@container_class}>
      <label for={@id} class="block">
        <span
          :if={@label}
          class="mb-1 block text-sm font-medium text-muted"
        >
          {@label}
        </span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || text_input_class(),
            @errors != [] && (@error_class || invalid_class())
          ]}
          {@rest}
        />
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  @doc "Interpolates a validation message's `%{key}` placeholders."
  @spec translate_error({String.t(), keyword()}) :: String.t()
  def translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", fn _match -> to_string(value) end)
    end)
  end

  slot :inner_block, required: true

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-danger">
      <CoreComponents.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  defp field_name(field, true), do: field.name <> "[]"
  defp field_name(field, false), do: field.name

  defp select_class do
    "w-full rounded-lg border border-edge bg-surface px-3 py-2 text-sm text-ink " <>
      "outline-none transition focus:border-accent focus:ring-2 focus:ring-accent/20"
  end

  defp text_input_class do
    "w-full rounded-lg border border-edge bg-surface px-3 py-2 text-sm text-ink " <>
      "outline-none transition placeholder:text-faint focus:border-accent " <>
      "focus:ring-2 focus:ring-accent/20"
  end

  defp invalid_class do
    "border-danger focus:border-danger focus:ring-danger/20"
  end
end
