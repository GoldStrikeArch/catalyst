defmodule Catalyst.Runtime.Sources.Core do
  @moduledoc """
  Read-model adapter for Catalyst's specialized core registries.

  Workflow claims include every currently valid precedence layer. Provider and
  policy registries currently export their effective value; the source metadata
  reports that reduced coverage explicitly.
  """

  alias Catalyst.Context.Registry, as: ContextRegistry
  alias Catalyst.LLM.Registry, as: ProviderRegistry
  alias Catalyst.Prompt.Registry, as: PromptRegistry
  alias Catalyst.Runtime.{Claim, Context, ContractRef, Contribution, RunEngine, Scope, ServiceKey}
  alias Catalyst.Tools.Registry, as: ToolRegistry

  @doc "Capture core service claims and additive contributions."
  @spec snapshot(Context.t()) ::
          {:ok, %{claims: [Claim.t()], contributions: [Contribution.t()], metadata: map()}}
  def snapshot(%Context{} = context) do
    {:ok,
     %{
       claims: service_claims(context),
       contributions: contributions(),
       metadata: %{
         workflow_layers: :full_valid_chain,
         provider_layers: :effective_only,
         prompt_policy_layers: :effective_only,
         context_policy_layers: :effective_only,
         registries: registry_health()
       }
     }}
  end

  defp service_claims(context) do
    RunEngine.all_claims(context) ++
      provider_claims() ++ prompt_policy_claims() ++ context_policy_claims()
  end

  defp provider_claims do
    owners = ProviderRegistry.runtime_owners()
    configured = Application.get_env(:catalyst, :llm_providers, %{})

    ProviderRegistry.list()
    |> Enum.map(fn {api, config} ->
      {owner, priority, provenance} = provider_origin(api, owners, configured)

      claim(
        ServiceKey.new!("llm", "provider", api),
        ContractRef.new!("catalyst.llm-provider", 1),
        config.module,
        owner,
        priority,
        {:pin, :request},
        provenance,
        %{config: config}
      )
    end)
  end

  defp prompt_policy_claims do
    case PromptRegistry.policy() do
      {:ok, module, source} ->
        [
          claim(
            ServiceKey.new!("agent", "prompt_policy"),
            ContractRef.new!("catalyst.prompt-policy", 1),
            module,
            source_owner(source),
            source_priority(source),
            {:pin, :request},
            source
          )
        ]

      {:error, _reason} ->
        []
    end
  end

  defp context_policy_claims do
    case ContextRegistry.policy() do
      {:ok, module, source} ->
        [
          claim(
            ServiceKey.new!("agent", "context_policy"),
            ContractRef.new!("catalyst.context-policy", 1),
            module,
            source_owner(source),
            source_priority(source),
            {:pin, :run},
            source
          )
        ]

      {:error, _reason} ->
        []
    end
  end

  defp contributions do
    tool_contributions() ++
      hook_contributions() ++ prompt_contributions() ++ context_threshold_contributions()
  end

  defp tool_contributions do
    owner_by_name = extension_tool_owners()
    builtins = MapSet.new(ToolRegistry.default_tools())

    Catalyst.Extensions.names()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case Catalyst.Extensions.fetch(name) do
        {:ok, module} ->
          {owner, provenance} = tool_origin(name, module, owner_by_name, builtins)
          [contribution("agent.tool", name, module, owner, provenance)]

        :error ->
          []
      end
    end)
  end

  defp extension_tool_owners do
    Catalyst.Extensions.list_loaded()
    |> Enum.flat_map(fn extension -> Enum.map(extension.tools, &{&1, extension.owner}) end)
    |> Map.new()
  catch
    :exit, _reason -> %{}
  end

  defp hook_contributions do
    Catalyst.Hooks.points()
    |> Enum.flat_map(fn point ->
      point
      |> Catalyst.Hooks.handlers()
      |> Enum.map(fn entry ->
        contribution(
          "agent.hook",
          {point, entry.id, entry.seq},
          %{point: point, priority: entry.priority},
          entry.owner || :host,
          {:hook_registry, point, entry.seq}
        )
      end)
    end)
  end

  defp prompt_contributions do
    PromptRegistry.runtime_entries()
    |> Enum.flat_map(fn
      %{key: {:text, _purpose, _model_key} = key, value: text, owner: owner} ->
        [contribution("agent.prompt", key, text, owner, {:prompt_registry, key})]

      _policy ->
        []
    end)
  end

  defp context_threshold_contributions do
    ContextRegistry.runtime_entries()
    |> Enum.flat_map(fn
      %{key: {:threshold, _model_key} = key, value: value, owner: owner} ->
        [
          contribution(
            "agent.context_threshold",
            key,
            value,
            owner,
            {:context_registry, key}
          )
        ]

      _policy ->
        []
    end)
  end

  defp claim(key, contract, implementation, owner, priority, binding, provenance, metadata \\ %{}) do
    %Claim{
      key: key,
      contract: contract,
      implementation: implementation,
      owner: owner,
      scope: Scope.global(),
      priority: priority,
      binding: binding,
      provenance: provenance,
      metadata: metadata
    }
  end

  defp contribution(point, id, value, owner, provenance) do
    %Contribution{
      point: point,
      id: id,
      value: value,
      owner: owner,
      scope: Scope.global(),
      provenance: provenance
    }
  end

  defp provider_origin(api, owners, configured) do
    case Map.fetch(owners, api) do
      {:ok, owner} -> {owner, 800, {:runtime, owner, {:provider, api}}}
      :error -> configured_provider_origin(api, configured)
    end
  end

  defp configured_provider_origin(api, configured) when is_map(configured) do
    case Map.has_key?(configured, api) do
      true -> {:application, 600, {:application, {:llm_providers, api}}}
      false -> {:builtin, 0, :builtin}
    end
  end

  defp configured_provider_origin(_api, _malformed), do: {:builtin, 0, :builtin}

  defp tool_origin(name, module, owner_by_name, builtins) do
    cond do
      Map.has_key?(owner_by_name, name) ->
        owner = Map.fetch!(owner_by_name, name)
        {owner, {:extension, owner, {:tool, name}}}

      MapSet.member?(builtins, module) ->
        {:builtin, :builtin}

      true ->
        {:host, :host}
    end
  end

  defp source_owner({:extension, owner, _key}), do: owner
  defp source_owner({:application, _setting}), do: :application
  defp source_owner(:builtin), do: :builtin

  defp source_priority({:extension, _owner, _key}), do: 800
  defp source_priority({:application, _setting}), do: 600
  defp source_priority(:builtin), do: 0

  defp registry_health do
    %{
      tools: table_health(:catalyst_tools),
      hooks: table_health(:catalyst_hooks),
      providers: table_health(:catalyst_llm_providers),
      prompts: table_health(:catalyst_prompt_registry),
      workflows: table_health(:catalyst_workflows),
      context: table_health(:catalyst_context_registry)
    }
  end

  defp table_health(table) do
    case :ets.whereis(table) do
      :undefined -> :unavailable
      _reference -> :ready
    end
  end
end
