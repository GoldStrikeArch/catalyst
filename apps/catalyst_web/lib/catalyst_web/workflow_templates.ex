defmodule CatalystWeb.WorkflowTemplates do
  @moduledoc """
  Narrow web adapter for the workflow template store.

  The implementation is configurable with `:workflow_template_store` in the
  `:catalyst_web` application. The default is
  `Catalyst.Workflow.Template.Store`; tests can provide a behaviour fake.
  """

  @type template :: map()
  @type attrs :: map()
  @type reason :: term()

  @callback list() :: {:ok, [template()]} | {:error, reason()}
  @callback built_ins() :: {:ok, [template()]} | {:error, reason()}
  @callback get(String.t()) :: {:ok, template()} | {:error, reason()}
  @callback create(attrs()) :: {:ok, template()} | {:error, reason()}
  @callback update(String.t(), attrs()) :: {:ok, template()} | {:error, reason()}
  @callback delete(String.t()) :: :ok | {:error, reason()}
  @callback duplicate(String.t(), attrs()) :: {:ok, template()} | {:error, reason()}

  @doc "Returns the configured workflow template store module."
  @spec store() :: module()
  def store do
    Application.get_env(
      :catalyst_web,
      :workflow_template_store,
      Catalyst.Workflow.Template.Store
    )
  end

  @doc "Calls a store operation without introducing a compile-time core dependency."
  @spec call(atom(), list()) :: term()
  def call(operation, arguments \\ []) do
    module = store()

    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, operation, length(arguments)) do
      apply(module, operation, arguments)
    else
      _unavailable -> {:error, :store_unavailable}
    end
  end
end
