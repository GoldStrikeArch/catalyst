defmodule Catalyst.Pack.Catalog do
  @moduledoc "Compiled allow-list of capability packs shipped with Catalyst."

  alias Catalyst.Pack.Manifest

  @version "0.1.0"
  @all_hosts [:cli, :web, :desktop]

  @manifests [
    Manifest.new!(%{
      id: "catalyst.meta-runtime",
      version: @version,
      trust: :compiled_trusted,
      hosts: @all_hosts
    }),
    Manifest.new!(%{
      id: "catalyst.agent.default",
      version: @version,
      trust: :compiled_trusted,
      dependencies: ["catalyst.meta-runtime"],
      hosts: @all_hosts
    }),
    Manifest.new!(%{
      id: "catalyst.workbench.default",
      version: @version,
      trust: :compiled_trusted,
      dependencies: ["catalyst.meta-runtime"],
      hosts: [:web, :desktop]
    }),
    Manifest.new!(%{
      id: "catalyst.provider.faux",
      version: @version,
      trust: :compiled_trusted,
      dependencies: ["catalyst.meta-runtime"],
      hosts: @all_hosts,
      services: [
        %{
          kind: :llm_provider,
          api: "faux",
          config: %{id: "faux", module: Catalyst.LLM.Faux, name: "Faux"}
        }
      ]
    }),
    Manifest.new!(%{
      id: "catalyst.provider.openai",
      version: @version,
      trust: :compiled_trusted,
      dependencies: ["catalyst.meta-runtime"],
      hosts: @all_hosts,
      services: [
        %{
          kind: :llm_provider,
          api: "openai-codex-responses",
          config: %{
            id: "openai-codex",
            module: Catalyst.LLM.OpenAICodex.Provider,
            name: "ChatGPT",
            catalog: Catalyst.LLM.OpenAICodex,
            auth: Catalyst.Auth.OpenAICodexFlow,
            controls: %{
              transports: ~w(auto websocket sse),
              legacy_web_login_env: :login_fun
            },
            catalog_priority: 100
          }
        }
      ]
    }),
    Manifest.new!(%{
      id: "catalyst.provider.grok",
      version: @version,
      trust: :compiled_trusted,
      dependencies: ["catalyst.meta-runtime"],
      hosts: @all_hosts,
      services: [
        %{
          kind: :llm_provider,
          api: "grok-subscription-chat-completions",
          config: %{
            id: "grok-subscription",
            module: Catalyst.LLM.GrokSubscription.Provider,
            name: "SuperGrok",
            catalog: Catalyst.LLM.GrokSubscription,
            auth: Catalyst.Auth.GrokFlow,
            controls: %{legacy_web_login_env: :grok_login_fun},
            catalog_priority: 200
          }
        }
      ]
    }),
    Manifest.new!(%{
      id: "catalyst.tools.coding",
      version: @version,
      trust: :compiled_trusted,
      dependencies: ["catalyst.meta-runtime", "catalyst.agent.default"],
      hosts: @all_hosts
    }),
    Manifest.new!(%{
      id: "catalyst.tools.self-development",
      version: @version,
      trust: :compiled_trusted,
      dependencies: [
        "catalyst.meta-runtime",
        "catalyst.agent.default",
        "catalyst.tools.coding"
      ],
      hosts: @all_hosts
    }),
    Manifest.new!(%{
      id: "catalyst.ide.core",
      version: @version,
      trust: :compiled_trusted,
      dependencies: [
        "catalyst.meta-runtime",
        "catalyst.agent.default",
        "catalyst.workbench.default"
      ],
      hosts: [:web, :desktop]
    })
  ]

  @doc "Return the immutable manifests compiled into this release."
  @spec all() :: [Manifest.t()]
  def all, do: @manifests
end
