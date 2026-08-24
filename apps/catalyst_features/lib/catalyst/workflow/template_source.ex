defmodule Catalyst.Workflow.TemplateSource do
  @moduledoc false

  @behaviour Catalyst.Workflow.Source

  alias Catalyst.Workflow.Template

  @impl true
  def list do
    case store_call(:list, []) do
      {:ok, templates} when is_list(templates) ->
        for %Template{id: id} <- templates, is_binary(id) and id != "", do: id

      _missing_or_invalid ->
        []
    end
  end

  @impl true
  def fetch(name) do
    case store_call(:fetch, [name]) do
      {:ok, %Template{id: ^name} = template} ->
        {:ok, Catalyst.Workflow.Runner,
         %{source: {:template, metadata(template)}, template: template}}

      {:ok, %Template{id: other}} ->
        {:error, {:workflow_template_name_mismatch, name, other}}

      {:ok, invalid} ->
        {:error, {:invalid_workflow_template, name, invalid}}

      :error ->
        :error

      {:error, :not_found} ->
        :error

      {:error, reason} ->
        {:error, {:workflow_template_store, reason}}

      other ->
        {:error, {:invalid_workflow_template_store_response, :fetch, other}}
    end
  end

  defp metadata(template) do
    %{
      id: template.id,
      name: template.name,
      version: template.version,
      digest: Template.digest(template)
    }
  end

  defp store_call(function, arguments) do
    store =
      Application.get_env(
        :catalyst,
        :workflow_template_store,
        Catalyst.Workflow.Store
      )

    case is_atom(store) and Code.ensure_loaded?(store) and
           function_exported?(store, function, length(arguments)) do
      true -> apply(store, function, arguments)
      false -> :error
    end
  end
end
