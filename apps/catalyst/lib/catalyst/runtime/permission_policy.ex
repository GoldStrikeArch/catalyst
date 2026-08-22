defmodule Catalyst.Runtime.PermissionPolicy do
  @moduledoc """
  Action-bound Runtime Graph adapter for brokered permission decisions.

  Policy callbacks run in a bounded supervised task and fail closed. The
  generation handle remains leased until the callback finishes or is killed.
  """

  alias Catalyst.Contracts.PermissionPolicy.V1
  alias Catalyst.Runtime.{Claim, Context, ContractRef, ExtensionPoints, Generations}
  alias Catalyst.Runtime.{Handle, Resolution, Resolver, Scope, ServiceKey, Transport}
  alias Catalyst.Tasks

  @default_timeout 10_000

  @doc "Authorize one brokered action through the effective policy."
  @spec authorize(map(), map(), map(), map()) :: V1.decision()
  def authorize(action, principal, resource, context)
      when is_map(action) and is_map(principal) and is_map(resource) and is_map(context) do
    runtime_context =
      Context.host(
        session_id: Map.get(principal, :session_id),
        run_id: Map.get(context, :run_id)
      )

    case resolve_and_pin(runtime_context, self(), 1) do
      {:ok, handle} -> invoke_and_release(handle, action, principal, resource, context)
      {:error, reason} -> {:deny, {:permission_policy_unavailable, reason}}
    end
  end

  def authorize(action, principal, resource, context),
    do: {:deny, {:invalid_permission_request, action, principal, resource, context}}

  @doc "Explain the effective permission policy without invoking it."
  @spec explain(Context.t() | map() | keyword()) :: Catalyst.Runtime.Explanation.t()
  def explain(context \\ %{}) do
    Resolver.explain(claims(), key(), Context.host(context), contract: V1.ref())
  end

  @doc "Export managed and built-in permission-policy claims."
  @spec claims() :: [Claim.t()]
  def claims, do: managed_claims() ++ [builtin_claim()]

  @doc false
  @spec unmanaged_claims() :: [Claim.t()]
  def unmanaged_claims, do: [builtin_claim()]

  @doc "Return the default permission-policy service key."
  @spec key() :: ServiceKey.t()
  def key, do: ServiceKey.new!("agent", "permission_policy", "default")

  defp resolve_and_pin(context, owner, retries) do
    with {:ok, resolution} <- resolve(context),
         result <- pin(resolution, owner) do
      case result do
        {:error, {:stale_runtime_generation, _requested, _active}} when retries > 0 ->
          resolve_and_pin(context, owner, retries - 1)

        other ->
          other
      end
    end
  end

  defp resolve(context) do
    case Resolver.resolve(claims(), key(), context, contract: V1.ref()) do
      {:ok, resolution} -> {:ok, resolution}
      {:error, explanation} -> {:error, explanation.status}
    end
  end

  defp pin(%Resolution{} = resolution, owner) do
    case Map.get(resolution.claim.metadata, :runtime_generation) do
      nil -> {:ok, Handle.new(resolution, nil)}
      _generation -> acquire_handle(resolution, owner)
    end
  end

  defp acquire_handle(resolution, owner) do
    with {:ok, lease} <- Generations.acquire_lease(resolution, owner) do
      {:ok, Handle.new(resolution, lease)}
    end
  end

  defp invoke_and_release(handle, action, principal, resource, context) do
    try do
      task =
        Tasks.async(fn ->
          invoke(handle, action, principal, resource, context)
        end)

      task
      |> Tasks.await(policy_timeout())
      |> normalize_decision()
    after
      Handle.release(handle)
    end
  end

  defp invoke(%Handle{} = handle, action, principal, resource, context) do
    Transport.invoke(handle, :authorize, [action, principal, resource, context])
  end

  defp normalize_decision({:ok, :allow}), do: :allow
  defp normalize_decision({:ok, {:deny, _reason} = denied}), do: denied

  defp normalize_decision({:ok, {:challenge, challenge}}) when is_map(challenge),
    do: {:challenge, challenge}

  defp normalize_decision({:ok, invalid}),
    do: {:deny, {:invalid_permission_decision, invalid}}

  defp normalize_decision({:exit, reason}), do: {:deny, {:permission_policy_exit, reason}}
  defp normalize_decision(:timeout), do: {:deny, :permission_policy_timeout}

  defp managed_claims do
    ExtensionPoints.list_claims()
    |> Enum.filter(&(&1.key == key()))
    |> Enum.filter(&ContractRef.compatible?(&1.contract, V1.ref()))
  end

  defp builtin_claim do
    %Claim{
      key: key(),
      contract: V1.ref(),
      implementation: Catalyst.Permissions.AllowAll,
      owner: :builtin,
      scope: Scope.global(),
      priority: 0,
      binding: {:pin, :action},
      provenance: :builtin,
      metadata: %{}
    }
  end

  defp policy_timeout do
    case Application.get_env(:catalyst, :permission_policy_timeout, @default_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> @default_timeout
    end
  end
end
