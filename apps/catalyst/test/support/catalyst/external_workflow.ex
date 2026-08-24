defmodule Catalyst.Test.ExternalWorkflow do
  @moduledoc false

  @behaviour Catalyst.Workflow

  @impl true
  def run(_prompts, _context, _config, _emit), do: {:ok, [], %{}}

  @impl true
  def provider_required?, do: false

  @impl true
  def session_backend(_selection, _opts), do: {:external, __MODULE__}
end
