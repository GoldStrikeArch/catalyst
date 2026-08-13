defmodule CatalystWeb.PromptsPageTest do
  use CatalystWeb.ConnCase, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]
  import Phoenix.LiveViewTest

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_prompts_page_#{System.unique_integer([:positive, :monotonic])}"
      )

    previous =
      Map.new([:prompts_dir, :system_prompt_path, :codex_models], fn key ->
        {key, Application.fetch_env(:catalyst, key)}
      end)

    Application.put_env(:catalyst, :prompts_dir, Path.join(root, "prompts"))
    Application.put_env(:catalyst, :system_prompt_path, Path.join(root, "system_prompt.md"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "the built-in page exposes durable default, API, model, and append editors", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/prompts")

    assert has_element?(view, "#page-nav-prompts", "Models & Prompts")
    assert has_element?(view, "#prompt-row-default")
    assert has_element?(view, "#prompt-row-api-openai-codex-responses")
    assert has_element?(view, "#prompt-row-model-gpt-5\\.6-sol")
    assert has_element?(view, "#prompt-row-append")
    assert has_element?(view, "#prompt-form-model-gpt-5\\.6-sol")
  end

  test "saving and resetting a model prompt updates its file-backed resolution", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/prompts")
    selector = "#prompt-form-model-gpt-5\\.6-sol"

    view
    |> form(selector)
    |> render_submit(%{
      "target" => "model:gpt-5.6-sol",
      "text" => "Use the model-specific test prompt."
    })

    assert File.read!(Path.join(Catalyst.SystemPrompt.prompts_dir(), "gpt-5.6-sol.md")) ==
             "Use the model-specific test prompt."

    assert has_element?(view, "#prompt-row-model-gpt-5\\.6-sol", "custom")
    assert has_element?(view, "#prompt-reset-model-gpt-5\\.6-sol")

    view
    |> element("#prompt-reset-model-gpt-5\\.6-sol")
    |> render_click()

    refute File.exists?(Path.join(Catalyst.SystemPrompt.prompts_dir(), "gpt-5.6-sol.md"))
    assert has_element?(view, "#prompt-row-model-gpt-5\\.6-sol", "inherited")
  end

  test "blank saves are rejected without replacing the current prompt", %{conn: conn} do
    path = Catalyst.SystemPrompt.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "keep me")

    {:ok, view, _html} = live(conn, "/prompts")

    html =
      view
      |> form("#prompt-form-default")
      |> render_submit(%{"target" => "default", "text" => " \n "})

    assert html =~ "Prompt cannot be blank"
    assert File.read!(path) == "keep me"
  end

  test "custom model ids use safe distinct editor and file identifiers", %{conn: conn} do
    model_id = "org/model with spaces"
    Application.put_env(:catalyst, :codex_models, [%{id: model_id, name: "Custom model"}])

    digest =
      model_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    dom_id = "model-org_model_with_spaces-#{digest}"
    {:ok, view, _html} = live(conn, "/prompts")

    assert has_element?(view, "#prompt-row-#{dom_id}")
    assert has_element?(view, "#prompt-form-#{dom_id}")

    view
    |> form("#prompt-form-#{dom_id}")
    |> render_submit(%{"target" => "model:#{model_id}", "text" => "Custom model prompt"})

    assert {:ok, path} = Catalyst.Prompt.Store.path({:model, model_id})
    assert File.read!(path) == "Custom model prompt"
  end

  test "existing invalid UTF-8 prompt files render repaired text", %{conn: conn} do
    {:ok, path} = Catalyst.Prompt.Store.path({:model, "gpt-5.6-sol"})
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, <<"bad", 255, "text">>)

    {:ok, view, _html} = live(conn, "/prompts")

    assert has_element?(view, "#prompt-text-model-gpt-5\\.6-sol", "bad�text")
  end
end
