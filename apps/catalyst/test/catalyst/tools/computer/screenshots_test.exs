defmodule Catalyst.Tools.Computer.ScreenshotsTest do
  # async: false — the hook test flips the global :computer_screenshot_retain.
  use ExUnit.Case, async: false

  alias Catalyst.{Content, Message}
  alias Catalyst.Tools.Computer.Screenshots

  defp screenshot(n) do
    %Message.ToolResult{
      tool_call_id: "c#{n}",
      tool_name: "computer",
      content: [
        %Content.Text{text: "Screenshot #{n}"},
        %Content.Image{data: Base.encode64("image-#{n}"), mime_type: "image/png"}
      ]
    }
  end

  defp other_image_result do
    %Message.ToolResult{
      tool_call_id: "r1",
      tool_name: "read",
      content: [%Content.Image{data: Base.encode64("photo"), mime_type: "image/jpeg"}]
    }
  end

  defp images(messages) do
    for %Message.ToolResult{content: content} <- messages,
        %Content.Image{} = image <- content,
        do: image
  end

  test "keeps the last N screenshots and replaces earlier ones with placeholders" do
    messages = [
      Message.user("go"),
      screenshot(1),
      screenshot(2),
      other_image_result(),
      screenshot(3)
    ]

    pruned = Screenshots.prune(messages, 1)

    # Only the last computer screenshot survives; the read-tool image is not a
    # screenshot and is never pruned.
    assert [%Content.Image{mime_type: "image/jpeg"}, %Content.Image{} = last] = images(pruned)
    assert Base.decode64!(last.data) == "image-3"

    [_user, one, two, _read, _three] = pruned
    assert [_text, %Content.Text{text: placeholder}] = one.content
    assert placeholder =~ "screenshot pruned"
    assert placeholder =~ "image/png"
    assert [_text, %Content.Text{}] = two.content
  end

  test "keep 0 replaces every screenshot" do
    pruned = Screenshots.prune([screenshot(1), screenshot(2)], 0)
    assert [%Content.Image{mime_type: "image/jpeg"}] = images(pruned ++ [other_image_result()])
  end

  test "pruning is idempotent (the documented double invocation)" do
    messages = [screenshot(1), screenshot(2), screenshot(3)]
    once = Screenshots.prune(messages, 1)
    assert Screenshots.prune(once, 1) == once
  end

  test "a keep larger than the population changes nothing" do
    messages = [screenshot(1), screenshot(2)]
    assert Screenshots.prune(messages, 5) == messages
  end

  test "the hook honors the live retain setting and defaults to a no-op" do
    previous = Application.fetch_env(:catalyst, :computer_screenshot_retain)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:catalyst, :computer_screenshot_retain, value)
        :error -> Application.delete_env(:catalyst, :computer_screenshot_retain)
      end
    end)

    messages = [screenshot(1), screenshot(2)]

    Application.put_env(:catalyst, :computer_screenshot_retain, :all)
    assert {:ok, ^messages} = Screenshots.prune_hook(messages, %{})

    Application.put_env(:catalyst, :computer_screenshot_retain, 1)
    assert {:ok, pruned} = Screenshots.prune_hook(messages, %{})
    assert length(images(pruned)) == 1
  end

  test "register_hooks/0 is idempotent" do
    # The application registered the hook at boot; registering again must not
    # accumulate a second handler.
    :ok = Screenshots.register_hooks()
    :ok = Screenshots.register_hooks()

    handlers = Catalyst.Hooks.handlers(:transform_context)

    assert Enum.count(handlers, &(&1.id == :computer_screenshot_prune)) == 1
  end
end
