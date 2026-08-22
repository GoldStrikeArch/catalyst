defmodule CatalystWeb.RuntimeSource do
  @moduledoc "Runtime Graph read-model adapter for web UI contributions."

  alias Catalyst.Runtime.{Context, Contribution, Scope}
  alias CatalystWeb.{UI.Registry, Workbench}

  @doc "Capture currently registered pages, renderers, components, and commands."
  @spec snapshot(Context.t()) ::
          {:ok,
           %{
             claims: [Catalyst.Runtime.Claim.t()],
             contributions: [Contribution.t()],
             metadata: map()
           }}
          | {:error, :ui_registry_unavailable}
  def snapshot(%Context{}) do
    case Registry.available?() do
      true ->
        {:ok,
         %{
           claims: Workbench.unmanaged_claims(),
           contributions:
             page_contributions() ++
               renderer_contributions() ++ component_contributions() ++ command_contributions(),
           metadata: %{ui_layers: :effective_and_additive_entries}
         }}

      false ->
        {:error, :ui_registry_unavailable}
    end
  end

  defp page_contributions do
    Registry.list_pages()
    |> Enum.map(fn page ->
      contribution(
        "ui.page",
        page.path,
        %{module: page.mod, function: page.fun, label: page.label},
        page.owner,
        {:ui_registry, :page, page.path}
      )
    end)
  end

  defp renderer_contributions do
    Registry.list_renderers()
    |> Enum.map(fn renderer ->
      contribution(
        "ui.renderer",
        {renderer.kind, renderer.seq},
        %{kind: renderer.kind, sequence: renderer.seq},
        renderer.owner,
        {:ui_registry, :renderer, renderer.kind, renderer.seq}
      )
    end)
  end

  defp component_contributions do
    Registry.list_components()
    |> Enum.map(fn component ->
      contribution(
        "ui.component",
        {component.slot, component.seq},
        %{slot: component.slot, sequence: component.seq},
        component.owner,
        {:ui_registry, :component, component.slot, component.seq}
      )
    end)
  end

  defp command_contributions do
    Registry.list_commands()
    |> Enum.map(fn command ->
      contribution(
        "ui.command",
        command.name,
        %{label: command.label, sequence: command.seq},
        command.owner,
        {:ui_registry, :command, command.name}
      )
    end)
  end

  defp contribution(point, id, value, owner, provenance) do
    %Contribution{
      point: point,
      id: id,
      value: value,
      owner: owner || :builtin,
      scope: Scope.global(),
      provenance: provenance
    }
  end
end
