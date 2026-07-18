defmodule CatalystWeb.DataComponents do
  @moduledoc """
  Generic table and description-list components for structured application data.
  """

  use Phoenix.Component

  @doc "Renders a table from a list or `Phoenix.LiveView.LiveStream`."
  attr :id, :string, required: true
  attr :rows, :any, required: true, doc: "a list or LiveView stream of rows"
  attr :row_id, :any, default: nil, doc: "the function for generating each row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the column and action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  @spec table(map()) :: Phoenix.LiveView.Rendered.t()
  def table(assigns) do
    assigns = assign_stream_row_id(assigns)

    ~H"""
    <div class="overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm dark:border-white/10 dark:bg-white/5">
      <table class="min-w-full divide-y divide-neutral-200 text-sm dark:divide-white/10">
        <thead class="bg-neutral-50 text-left text-xs font-semibold uppercase tracking-wide text-neutral-500 dark:bg-white/5 dark:text-neutral-400">
          <tr>
            <th :for={column <- @col} class="px-4 py-3">{column[:label]}</th>
            <th :if={@action != []} class="px-4 py-3">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={stream_update(@rows)}
          class="divide-y divide-neutral-100 dark:divide-white/10"
        >
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="transition hover:bg-neutral-50/80 dark:hover:bg-white/5"
          >
            <td
              :for={column <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                @row_click && "hover:cursor-pointer",
                "px-4 py-3 text-neutral-700 dark:text-neutral-200"
              ]}
            >
              {render_slot(column, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 px-4 py-3 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc "Renders a bordered list of titled data items."
  slot :item, required: true do
    attr :title, :string, required: true
  end

  @spec list(map()) :: Phoenix.LiveView.Rendered.t()
  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-neutral-100 rounded-2xl border border-neutral-200 bg-white shadow-sm dark:divide-white/10 dark:border-white/10 dark:bg-white/5">
      <li :for={item <- @item} class="px-4 py-3">
        <div class="font-semibold text-neutral-950 dark:text-white">{item.title}</div>
        <div class="mt-1 text-sm text-neutral-600 dark:text-neutral-300">{render_slot(item)}</div>
      </li>
    </ul>
    """
  end

  defp assign_stream_row_id(%{rows: %Phoenix.LiveView.LiveStream{}} = assigns) do
    assign(assigns, :row_id, assigns.row_id || fn {id, _item} -> id end)
  end

  defp assign_stream_row_id(assigns), do: assigns

  defp stream_update(%Phoenix.LiveView.LiveStream{}), do: "stream"
  defp stream_update(_rows), do: nil
end
