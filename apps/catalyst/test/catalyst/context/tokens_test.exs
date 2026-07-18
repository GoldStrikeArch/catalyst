defmodule Catalyst.Context.TokensTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Model, Usage}
  alias Catalyst.Context.Tokens
  alias Catalyst.LLM.Context, as: LLMContext
  alias Catalyst.LLM.OpenAICodex.{Provider, Request}

  setup do
    _ = Task.Supervisor.start_link(name: Catalyst.LLM.AdapterSupervisor)
    :ok
  end

  defmodule Adapter do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :not_used}

    @impl true
    def context_fingerprint(model, context, opts) do
      digest = Tokens.semantic_digest(model, context, opts)
      {:ok, :crypto.hash(:sha256, "adapter:" <> digest)}
    end

    @impl true
    def estimate_tokens(_model, context, _opts), do: {:ok, 10 + length(context.messages) * 10}
  end

  defmodule NoAdapter do
    @behaviour Catalyst.LLM.Provider

    @impl true
    def stream(_model, _context, _opts, _sink), do: {:error, :not_used}
  end

  defmodule UnknownBlock do
    @moduledoc false
    defstruct [:value]
  end

  defp model(input \\ [:text, :image]) do
    %Model{
      id: "gpt-test",
      api: "openai-codex-responses",
      provider: "openai-codex",
      input: input
    }
  end

  test "provider adapters supply the estimate and resumable anchor fingerprint" do
    prior = %LLMContext{system_prompt: "system", messages: [Message.user("hello")], tools: []}

    assistant = %Message.Assistant{
      content: Content.text("answer"),
      usage: %Usage{total_tokens: 100},
      stop_reason: :stop
    }

    anchored = Tokens.attach_context_digest(assistant, model(), prior, provider: Adapter)
    refute is_nil(anchored.usage.context_digest)
    assert byte_size(anchored.usage.context_digest) == 64

    next = %{prior | messages: prior.messages ++ [anchored, Message.user("more")]}

    assert {:ok, estimate} = Tokens.estimate(model(), next, provider: Adapter)
    assert estimate.source == :provider
    assert estimate.anchored
    assert estimate.tokens > 100

    changed = %{next | system_prompt: "changed"}
    assert {:ok, changed_estimate} = Tokens.estimate(model(), changed, provider: Adapter)
    refute changed_estimate.anchored
  end

  test "adapter-less providers with real totals remain coarsely estimated and unanchored" do
    context = %LLMContext{system_prompt: "system", messages: [Message.user("hello")], tools: []}

    assistant = %Message.Assistant{
      content: Content.text("answer"),
      usage: %Usage{total_tokens: 100, context_digest: "untrusted-provider-digest"},
      stop_reason: :stop
    }

    attached = Tokens.attach_context_digest(assistant, model(), context, provider: NoAdapter)
    assert attached.usage.context_digest == nil

    request = %{context | messages: context.messages ++ [attached, Message.user("more")]}

    assert {:ok, estimate} = Tokens.estimate(model(), request, provider: NoAdapter)
    refute estimate.anchored
    assert estimate.source == :coarse
  end

  test "legacy, zero-total, and failed usage remain unanchored" do
    context = %LLMContext{messages: [Message.user("hello")], tools: []}

    for assistant <- [
          %Message.Assistant{usage: %Usage{total_tokens: 0}, stop_reason: :stop},
          %Message.Assistant{usage: %Usage{total_tokens: 10}, stop_reason: :error},
          %Message.Assistant{usage: %Usage{total_tokens: 10}, stop_reason: :aborted}
        ] do
      assert Tokens.attach_context_digest(assistant, model(), context, provider: Adapter).usage.context_digest ==
               nil
    end

    legacy = %Message.Assistant{usage: %Usage{total_tokens: 100}, stop_reason: :stop}
    request = %{context | messages: context.messages ++ [legacy]}

    assert {:ok, %{anchored: false, source: :coarse}} =
             Tokens.estimate(model(), request, provider: NoAdapter)
  end

  test "the coarse fallback covers instructions, tools, structured content, and images" do
    base = %LLMContext{system_prompt: "short", messages: [Message.user("hi")], tools: []}

    rich = %LLMContext{
      system_prompt: String.duplicate("instruction ", 100),
      tools: [
        %{
          name: "search",
          description: String.duplicate("description ", 50),
          parameters: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
        }
      ],
      messages: [
        %Message.User{
          content: [
            %Content.Text{text: String.duplicate("message ", 100)},
            %Content.Image{data: "QUJD", mime_type: "image/png"}
          ]
        }
      ]
    }

    assert {:ok, base_estimate} = Tokens.estimate(model(), base, provider: NoAdapter)
    assert {:ok, rich_estimate} = Tokens.estimate(model(), rich, provider: NoAdapter)
    assert base_estimate.source == :coarse
    assert rich_estimate.tokens > base_estimate.tokens + 1_024
  end

  test "provider-neutral thinking projections include text, signature, and redaction" do
    generic = %Model{id: "generic", api: "generic", provider: "generic"}
    signature = Jason.encode!(%{"id" => "reason-1", "type" => "reasoning"})

    context = %LLMContext{
      messages: [
        %Message.Assistant{
          content: [
            %Content.Thinking{
              thinking: "private-a",
              signature: signature,
              redacted: false
            }
          ]
        }
      ],
      tools: []
    }

    digest = Tokens.semantic_digest(generic, context)

    changed_thinking =
      put_in(context.messages, [
        %Message.Assistant{
          content: [
            %Content.Thinking{
              thinking: "private-b",
              signature: signature,
              redacted: false
            }
          ]
        }
      ])

    changed_signature =
      put_in(context.messages, [
        %Message.Assistant{
          content: [
            %Content.Thinking{
              thinking: "private-a",
              signature: Jason.encode!(%{"id" => "reason-2", "type" => "reasoning"}),
              redacted: false
            }
          ]
        }
      ])

    changed_redaction =
      put_in(context.messages, [
        %Message.Assistant{
          content: [
            %Content.Thinking{
              thinking: "private-a",
              signature: signature,
              redacted: true
            }
          ]
        }
      ])

    refute Tokens.semantic_digest(generic, changed_thinking) == digest
    refute Tokens.semantic_digest(generic, changed_signature) == digest
    refute Tokens.semantic_digest(generic, changed_redaction) == digest

    assert codex_digest(model(), context) == codex_digest(model(), changed_thinking)

    assert codex_digest(model(), context) == codex_digest(model(), changed_redaction)
  end

  defmodule TimeoutAdapter do
    @behaviour Catalyst.LLM.Provider
    @impl true
    def stream(_, _, _, _), do: {:error, :not_used}
    @impl true
    def estimate_tokens(_, _, _),
      do:
        (
          Process.sleep(100)
          {:ok, 100}
        )
  end

  defmodule CrashAdapter do
    @behaviour Catalyst.LLM.Provider
    @impl true
    def stream(_, _, _, _), do: {:error, :not_used}
    @impl true
    def estimate_tokens(_, _, _), do: raise("adapter crash")
  end

  test "adapter timeouts and crashes are handled gracefully" do
    # Ensure supervisor is running (it should be in tests if started by app)
    # But for isolation we might need to start it if not present.
    _ = Task.Supervisor.start_link(name: Catalyst.LLM.AdapterSupervisor)

    ctx = %LLMContext{messages: [], tools: []}

    # Timeout
    assert {:error, {:context_adapter_timeout, TimeoutAdapter, :estimate_tokens, 10}} =
             Tokens.estimate_tokens(model(), ctx, provider: TimeoutAdapter, adapter_timeout: 10)

    # Crash
    assert {:error,
            {:context_adapter_exit, CrashAdapter, :estimate_tokens,
             {%RuntimeError{message: "adapter crash"}, _stack}}} =
             Tokens.estimate_tokens(model(), ctx, provider: CrashAdapter)
  end

  test "Codex semantic projection stays equivalent to the wire encoder" do
    signature =
      Jason.encode!(%{
        "type" => "reasoning",
        "id" => "reasoning-1",
        "encrypted_content" => "opaque"
      })

    context = %LLMContext{
      system_prompt: "system",
      tools: [
        %{
          name: "read",
          description: "read a file",
          parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
        }
      ],
      messages: [
        %Message.User{
          content: [
            %Content.Text{text: "inspect this"},
            %Content.Image{data: "IMAGE", mime_type: "image/png"}
          ]
        },
        %Message.Assistant{
          content: [
            %Content.Thinking{thinking: "private", signature: signature},
            %Content.Text{text: "calling read"},
            %Content.ToolCall{
              id: "call-1|item-1",
              name: "read",
              arguments: %{"path" => "README.md"}
            }
          ]
        },
        %Message.ToolResult{
          tool_call_id: "call-1|item-1",
          tool_name: "read",
          content: [
            %Content.Text{text: "contents"},
            %Content.Image{data: "RESULT", mime_type: "image/jpeg"}
          ]
        }
      ]
    }

    opts = [
      session_id: "session-1",
      text_verbosity: "medium",
      service_tier: "priority",
      reasoning_effort: "high",
      reasoning_summary: "detailed"
    ]

    wire = Request.build(model(), context, opts)
    projection = Request.semantic_projection(model(), context, opts)

    assert projection.instructions == wire["instructions"]
    assert json_value(projection.tools) == wire["tools"]

    assert json_value(projection.options) == %{
             "text_verbosity" => get_in(wire, ["text", "verbosity"]),
             "prompt_cache_key" => wire["prompt_cache_key"],
             "service_tier" => wire["service_tier"],
             "reasoning" => wire["reasoning"]
           }

    assert json_value(projection.messages) == Enum.map(wire["input"], &normalize_wire_item/1)
    assert Tokens.estimate_projection(projection) >= 2 * 1_024
  end

  test "Codex-visible content, item ids, tool schemas, and request options invalidate digests" do
    vision = model()

    base = %LLMContext{
      system_prompt: "system",
      tools: [%{name: "read", description: "read", parameters: %{"type" => "object"}}],
      messages: [
        %Message.User{content: [%Content.Image{data: "IMAGE-A", mime_type: "image/png"}]},
        %Message.Assistant{
          content: [
            %Content.Thinking{
              thinking: "hidden",
              signature: Jason.encode!(%{"type" => "reasoning", "id" => "reason-1"})
            },
            %Content.ToolCall{id: "call-1|item-1", name: "read", arguments: %{"path" => "a"}}
          ]
        }
      ]
    }

    digest = codex_digest(vision, base, session_id: "session")

    json_equivalent = %{
      base
      | tools: [%{name: "read", description: "read", parameters: %{type: "object"}}],
        messages: [
          Enum.at(base.messages, 0),
          %Message.Assistant{
            content: [
              %Content.Thinking{
                thinking: "hidden",
                signature: Jason.encode!(%{"type" => "reasoning", "id" => "reason-1"})
              },
              %Content.ToolCall{id: "call-1|item-1", name: "read", arguments: %{path: "a"}}
            ]
          }
        ]
    }

    assert codex_digest(vision, json_equivalent, session_id: "session") == digest

    changed_image =
      put_in(base.messages, [
        %Message.User{content: [%Content.Image{data: "IMAGE-B", mime_type: "image/png"}]},
        Enum.at(base.messages, 1)
      ])

    changed_item =
      put_in(base.messages, [
        Enum.at(base.messages, 0),
        %Message.Assistant{
          content: [
            %Content.Thinking{
              thinking: "hidden",
              signature: Jason.encode!(%{"type" => "reasoning", "id" => "reason-2"})
            },
            %Content.ToolCall{id: "call-1|item-2", name: "read", arguments: %{"path" => "a"}}
          ]
        }
      ])

    changed_tools =
      put_in(base.tools, [
        %{name: "read", description: "changed", parameters: %{"type" => "object"}}
      ])

    refute codex_digest(vision, changed_image, session_id: "session") == digest
    refute codex_digest(vision, changed_item, session_id: "session") == digest
    refute codex_digest(vision, changed_tools, session_id: "session") == digest

    refute codex_digest(vision, base,
             session_id: "session",
             service_tier: "priority"
           ) == digest
  end

  defp normalize_wire_item(%{"type" => "message"} = item), do: Map.delete(item, "id")

  defp normalize_wire_item(%{"type" => "function_call", "arguments" => arguments} = item) do
    Map.put(item, "arguments", Jason.decode!(arguments))
  end

  defp normalize_wire_item(item), do: item

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp codex_digest(model, context, opts \\ []) do
    model
    |> Request.semantic_projection(context, opts)
    |> Tokens.projection_digest()
  end
end
