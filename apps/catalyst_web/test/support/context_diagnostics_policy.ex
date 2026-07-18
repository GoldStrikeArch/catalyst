defmodule CatalystWeb.Test.ContextDiagnosticsPolicy do
  @moduledoc false

  @behaviour Catalyst.Context.Policy

  @impl true
  def threshold(_model, _context), do: raise("diagnostics must not invoke custom policies")

  @impl true
  def compact(_messages, _context), do: {:error, :not_used}
end
