defmodule Catalyst.Prompt.StoreTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Prompt.Store

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_prompt_store_#{System.unique_integer([:positive, :monotonic])}"
      )

    previous =
      Map.new([:prompts_dir, :system_prompt_path], fn key ->
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

  test "stores, reads, and deletes every editable prompt target" do
    targets = [:default, :append, {:api, "codex-api"}, {:model, "model-one"}]

    Enum.each(targets, fn target ->
      assert :missing = Store.read(target)
      assert :ok = Store.save(target, "prompt for #{inspect(target)}")
      assert {:ok, "prompt for " <> _rest} = Store.read(target)
      assert {:ok, path} = Store.path(target)
      assert File.regular?(path)
      assert :ok = Store.delete(target)
      assert :missing = Store.read(target)
      assert :ok = Store.delete(target)
    end)
  end

  test "rejects blank, oversized, invalid UTF-8, and blank model keys" do
    assert {:error, :blank_prompt} = Store.save(:default, " \n ")
    assert {:error, :prompt_too_large} = Store.save(:default, String.duplicate("x", 65_537))
    assert {:error, :invalid_prompt_utf8} = Store.save(:default, <<"bad", 255>>)

    assert {:error, {:invalid_prompt_key, :api, ""}} = Store.path({:api, ""})
  end

  test "uses the resolver slug for arbitrary nonblank model keys" do
    key = "../../outside model/with spaces"

    assert :ok = Store.save({:model, key}, "safe model prompt")
    assert {:ok, path} = Store.path({:model, key})
    assert Path.dirname(path) == Catalyst.SystemPrompt.prompts_dir()
    assert Path.basename(path) == Catalyst.SystemPrompt.slug(key) <> ".md"
    assert File.read!(path) == "safe model prompt"
  end

  test "repairs invalid UTF-8 read from an existing prompt file" do
    {:ok, path} = Store.path({:model, "model-one"})
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, <<"bad", 255, "text">>)

    assert {:ok, "bad�text"} = Store.read({:model, "model-one"})
  end

  test "a rejected replacement leaves the previous complete file intact" do
    assert :ok = Store.save({:model, "model-one"}, "original")

    assert {:error, :prompt_too_large} =
             Store.save({:model, "model-one"}, String.duplicate("x", 65_537))

    assert {:ok, "original"} = Store.read({:model, "model-one"})
  end
end
