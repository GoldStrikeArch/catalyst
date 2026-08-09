defmodule Catalyst.LLM.OpenAICodex.LiveWireTest do
  @moduledoc """
  Opt-in live wire contract test (`mix test --only live_wire`).

  Everything else in the suite talks to stubs. This one makes a real Codex turn
  because a single question cannot be answered any other way: does the backend
  accept a tool result whose `function_call_output` is an ITEM LIST carrying an
  `input_image` (`Catalyst.LLM.OpenAICodex.Request.convert_message/3`)? That
  shape is inherited from PI and is the foundation of every image-returning
  tool, so a regression here is a wire-contract change, not a local bug.

  Requires stored ChatGPT credentials at `~/.catalyst/auth.json`; skipped
  without them. The token store is repointed at that real file for the duration
  of the test so a token refresh persists where production would write it —
  otherwise a rotated refresh token would be stranded in the test tmp home and
  the user's real credentials would silently stop working.
  """

  use ExUnit.Case, async: false

  alias Catalyst.{Content, Message}
  alias Catalyst.LLM.Context, as: LLMContext
  alias Catalyst.LLM.OpenAICodex
  alias Catalyst.LLM.OpenAICodex.Provider

  @moduletag :live_wire

  @auth_path Path.join([System.user_home!(), ".catalyst", "auth.json"])

  # A valid 1x1 PNG — the smallest thing that is unambiguously an image.
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  @screenshot_tool %{
    name: "screenshot",
    description: "Capture the screen and return the image. Takes no arguments.",
    parameters: %{"type" => "object", "properties" => %{}, "required" => []}
  }

  case File.exists?(@auth_path) do
    true -> :ok
    false -> @moduletag skip: "no stored credentials at #{@auth_path}"
  end

  setup do
    original = Application.get_env(:catalyst, :auth_path)
    Application.put_env(:catalyst, :auth_path, @auth_path)
    restart_token_store!()

    on_exit(fn ->
      Application.put_env(:catalyst, :auth_path, original)
      restart_token_store!()
    end)

    :ok
  end

  test "the backend accepts a function_call_output item list carrying an image" do
    model = OpenAICodex.model()
    session_id = "live-wire-#{Catalyst.Ids.hex(8)}"
    opts = [session_id: session_id, transport: :sse]

    first = %LLMContext{
      system_prompt: "You are a test harness. Use the tools you are given.",
      tools: [@screenshot_tool],
      messages: [
        Message.user("Call the screenshot tool now. Reply with the tool call only.")
      ]
    }

    assert {:ok, %Message.Assistant{} = assistant} =
             Provider.stream(model, first, opts, fn _event -> :ok end)

    assert assistant.stop_reason != :error,
           "turn 1 failed before the image was ever sent: #{inspect(assistant.error_message)}"

    call =
      Enum.find_value(assistant.content, fn
        %Content.ToolCall{} = call -> call
        _other -> nil
      end)

    assert call,
           "the model did not call the tool, so the image contract was never exercised — " <>
             "rerun; this is an inconclusive result, not a contract failure"

    second = %{
      first
      | messages:
          first.messages ++
            [
              assistant,
              %Message.ToolResult{
                tool_call_id: call.id,
                tool_name: call.name,
                content: [
                  %Content.Text{text: "screenshot captured"},
                  %Content.Image{data: @png, mime_type: "image/png"}
                ]
              }
            ]
    }

    assert {:ok, %Message.Assistant{} = reply} =
             Provider.stream(model, second, opts, fn _event -> :ok end)

    assert reply.stop_reason != :error, wire_contract_failure(reply.error_message)
  end

  defp wire_contract_failure(message) do
    """
    THE CODEX WIRE CONTRACT CHANGED.

    The backend rejected a tool result shipped as a `function_call_output` whose
    `output` is an item list of `input_text` + `input_image` parts — the shape
    `Catalyst.LLM.OpenAICodex.Request.convert_message/3` has always produced for
    image-bearing tool results. Nothing local to this test can cause this.

    Documented fallback: inject the image as a separate user input item, the way
    the Codex CLI's `view_image` tool does, instead of as tool output.

    Backend error: #{inspect(message)}
    """
  end

  # The store is a named singleton under `Catalyst.Supervisor`; this tier runs
  # alone (`--only live_wire`), so bouncing it here races nothing.
  defp restart_token_store! do
    :ok = Supervisor.terminate_child(Catalyst.Supervisor, Catalyst.Auth.TokenStore)
    {:ok, _pid} = Supervisor.restart_child(Catalyst.Supervisor, Catalyst.Auth.TokenStore)
    :ok
  end
end
