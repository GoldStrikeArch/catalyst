defmodule Catalyst.Context.TokensTest do
  use ExUnit.Case, async: true

  alias Catalyst.{Content, Message, Model}
  alias Catalyst.Context.Tokens
  alias Catalyst.LLM.Context, as: LLMContext
  alias Catalyst.LLM.OpenAICodex.Request

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

  test "all providers use one deterministic coarse estimate" do
    context = %LLMContext{system_prompt: "system", messages: [Message.user("hello")], tools: []}

    assert {:ok, first} = Tokens.estimate(model(), context, provider: NoAdapter)
    assert {:ok, second} = Tokens.estimate(model(), context, provider: NoAdapter)
    assert first == second
    assert first.source == :coarse
    assert byte_size(first.context_digest) == 64
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

  describe "image token accounting" do
    test "a ~1 MB image costs low thousands of tokens on both the coarse and Codex paths" do
      context = image_context(base64_image(?a, 786_432))

      assert {:ok, coarse} = Tokens.estimate(model(), context, provider: NoAdapter)
      assert coarse.source == :coarse
      assert coarse.tokens in 1_600..4_000

      codex = Tokens.estimate_projection(Request.semantic_projection(model(), context, []))
      assert codex in 1_600..4_000
    end

    test "a ~5 MB image costs proportionally more and never lands on the floor" do
      small = image_context(base64_image(?a, 786_432))
      large = image_context(base64_image(?a, 3_932_160))

      assert {:ok, small_coarse} = Tokens.estimate(model(), small, provider: NoAdapter)
      assert {:ok, large_coarse} = Tokens.estimate(model(), large, provider: NoAdapter)

      assert large_coarse.tokens > 4 * small_coarse.tokens
      assert large_coarse.tokens > 8_000

      small_codex = Tokens.estimate_projection(Request.semantic_projection(model(), small, []))
      large_codex = Tokens.estimate_projection(Request.semantic_projection(model(), large, []))

      assert large_codex > 4 * small_codex
      assert large_codex > 8_000
    end

    test "projections carry a digest and byte size instead of the base64 payload" do
      data = base64_image(?a, 3_072)
      context = image_context(data)

      coarse_binary =
        model() |> Tokens.provider_projection(context, []) |> Tokens.canonical_binary()

      codex_json = model() |> Request.semantic_projection(context, []) |> Jason.encode!()

      refute String.contains?(coarse_binary, data)
      refute String.contains?(codex_json, data)
      assert String.contains?(codex_json, "image_digest")
    end

    test "two different images of the same size still produce different digests" do
      a = image_context(base64_image(?a, 3_072))
      b = image_context(base64_image(?b, 3_072))

      assert Tokens.semantic_digest(model(), a) == Tokens.semantic_digest(model(), a)
      refute Tokens.semantic_digest(model(), a) == Tokens.semantic_digest(model(), b)

      assert codex_digest(model(), a) == codex_digest(model(), a)
      refute codex_digest(model(), a) == codex_digest(model(), b)
    end

    test "an unchanged image-bearing prefix keeps the delta-upload hash stable" do
      context = image_context(base64_image(?a, 3_072))
      covered = context.messages
      covered_count = length(covered)

      # `Provider.next_continuation/2` stores the covered-prefix digest; the next
      # turn recomputes it over the same prefix of a longer transcript and must
      # get the same value, or every request falls back to a full upload.
      stored = codex_digest(model(), %{context | messages: covered})
      next_turn = %{context | messages: covered ++ [Message.user("and now?")]}

      assert prefix_digest(next_turn, covered_count) == stored

      rewritten = %{
        next_turn
        | messages: List.replace_at(next_turn.messages, 0, Message.user("different"))
      }

      refute prefix_digest(rewritten, covered_count) == stored
    end

    # AUDIT: `image_tokens/1` walks the whole projection, and `content_projection/1`
    # embeds a ToolCall's `arguments` verbatim — so a map the *model* wrote, merely
    # shaped like an image block, is priced as one. `bytes` is model-controlled and
    # unbounded, which makes the estimate (and therefore the compaction guard)
    # steerable by the assistant. Only harness-built image blocks may be costed.
    @tag :audit
    test "model-written tool arguments shaped like an image block do not inflate the estimate" do
      poisoned = tool_call_context(%{"type" => "input_image", "bytes" => 999_999_999_999})
      ordinary = tool_call_context(%{"type" => "input_image", "bytes" => "not-a-count"})

      assert {:ok, poisoned_tokens} = Tokens.estimate_tokens(nil, poisoned, [])
      assert {:ok, ordinary_tokens} = Tokens.estimate_tokens(nil, ordinary, [])

      # The two calls differ only in a value the model chose; the estimate must not.
      assert_in_delta poisoned_tokens, ordinary_tokens, 50
      assert poisoned_tokens < 10_000
    end
  end

  # A deterministic base64 payload of exactly `bytes * 4 / 3` characters.
  defp base64_image(byte, bytes), do: <<byte>> |> :binary.copy(bytes) |> Base.encode64()

  # Mirrors `Provider.delta_body/2`'s covered-prefix comparison.
  defp prefix_digest(context, covered_count),
    do: codex_digest(model(), %{context | messages: Enum.take(context.messages, covered_count)})

  defp image_context(data) do
    %LLMContext{
      system_prompt: "system",
      tools: [],
      messages: [
        Message.user("look at this"),
        %Message.ToolResult{
          tool_call_id: "call-1|item-1",
          tool_name: "computer",
          content: [
            %Content.Text{text: "captured"},
            %Content.Image{data: data, mime_type: "image/png"}
          ]
        }
      ]
    }
  end

  defp normalize_wire_item(%{"type" => "message"} = item), do: Map.delete(item, "id")

  defp normalize_wire_item(%{"type" => "function_call", "arguments" => arguments} = item) do
    Map.put(item, "arguments", Jason.decode!(arguments))
  end

  defp normalize_wire_item(%{"type" => "function_call_output", "output" => parts} = item)
       when is_list(parts),
       do: Map.put(item, "output", Enum.map(parts, &normalize_wire_part/1))

  defp normalize_wire_item(%{"role" => "user", "content" => parts} = item) when is_list(parts),
    do: Map.put(item, "content", Enum.map(parts, &normalize_wire_part/1))

  defp normalize_wire_item(item), do: item

  # The projection deliberately diverges from the wire body for images: the data
  # URL is replaced by its digest and payload size, and the block carries the
  # harness-built marker (`Tokens.tag_image_block/1` — an atom key, which
  # `json_value/1` stringifies) so only harness images are priced as images.
  defp normalize_wire_part(%{"type" => "input_image", "image_url" => url} = part) do
    [_prefix, payload] = String.split(url, ";base64,", parts: 2)

    part
    |> Map.delete("image_url")
    |> Map.put("image_digest", :sha256 |> :crypto.hash(url) |> Base.encode16(case: :lower))
    |> Map.put("bytes", byte_size(payload))
    |> Map.put("__catalyst_image__", true)
  end

  defp normalize_wire_part(part), do: part

  defp tool_call_context(arguments) do
    call = %Content.ToolCall{id: "call-1", name: "computer", arguments: arguments}

    %LLMContext{
      messages: [%Message.Assistant{content: [call], timestamp: Message.now()}]
    }
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp codex_digest(model, context, opts \\ []) do
    model
    |> Request.semantic_projection(context, opts)
    |> Tokens.projection_digest()
  end
end
