defmodule Catalyst.Permissions.AllowAll do
  @moduledoc "Default policy preserving Catalyst's trusted local execution behavior."

  @behaviour Catalyst.Contracts.PermissionPolicy.V1

  @impl true
  def authorize(_action, _principal, _resource, _context), do: :allow
end
