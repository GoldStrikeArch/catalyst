defmodule CatalystWeb.ShellLive do
  @moduledoc false

  use CatalystWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main
        id="flex-shell-shadow"
        class="flex min-h-screen items-center justify-center bg-violet-950 text-violet-50"
      >
        <h1 class="text-2xl font-semibold">FLEX-SHELL-SHADOW</h1>
      </main>
    </Layouts.app>
    """
  end
end
