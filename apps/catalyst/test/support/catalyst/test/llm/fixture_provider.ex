defmodule Catalyst.Test.LLM.FixtureProvider do
  @moduledoc false

  @behaviour Catalyst.LLM.Provider

  @impl true
  def stream(_model, _context, _opts, _sink), do: {:error, :unused}
end
