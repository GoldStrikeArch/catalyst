defmodule Catalyst.Resources do
  @moduledoc """
  Broker boundary for host actions governed by the runtime permission policy.

  This module makes authorization and the protected operation one explicit host
  call. It is enforceable for callers that use the broker; trusted code in the
  Catalyst VM can still bypass it and invoke operating-system APIs directly.
  """

  alias Catalyst.Runtime.PermissionPolicy

  @type request_error :: {:denied, term()} | {:challenge, map()}

  @doc """
  Authorize and perform one brokered operation.

  The zero-arity operation runs only after an `:allow` decision. Expected policy
  denials and human challenges are returned without invoking it.
  """
  @spec request(map(), map(), map(), map(), (-> result)) ::
          {:ok, result} | {:error, request_error()}
        when result: term()
  def request(action, principal, resource, context, operation)
      when is_map(action) and is_map(principal) and is_map(resource) and is_map(context) and
             is_function(operation, 0) do
    case PermissionPolicy.authorize(action, principal, resource, context) do
      :allow -> {:ok, operation.()}
      {:deny, reason} -> {:error, {:denied, reason}}
      {:challenge, challenge} -> {:error, {:challenge, challenge}}
    end
  end
end
