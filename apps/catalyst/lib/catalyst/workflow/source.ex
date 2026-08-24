defmodule Catalyst.Workflow.Source do
  @moduledoc """
  Contributes a dynamic family of named workflows.

  Sources are useful when names come from live configuration or durable files
  rather than one `register_workflow/4` call. They are registered by an
  extension and queried only during workflow resolution.
  """

  @type selection_metadata :: %{optional(:source) => term(), optional(:template) => term()}

  @doc "Return the currently selectable workflow names."
  @callback list() :: [String.t()]

  @doc "Resolve one name to a workflow module and optional selection metadata."
  @callback fetch(String.t()) ::
              {:ok, module()}
              | {:ok, module(), selection_metadata()}
              | :error
              | {:error, term()}
end
