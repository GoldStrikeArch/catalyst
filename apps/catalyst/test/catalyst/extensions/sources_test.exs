defmodule Catalyst.Extensions.SourcesTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Extensions.Sources

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_sources_#{System.unique_integer([:positive, :monotonic])}"
      )

    previous = Application.fetch_env(:catalyst, :extensions_dir)
    previous_bundled = Application.fetch_env(:catalyst, :bundled_extensions_dirs)
    Application.put_env(:catalyst, :extensions_dir, root)
    Application.put_env(:catalyst, :bundled_extensions_dirs, [])
    File.mkdir_p!(root)

    on_exit(fn ->
      restore_env(:extensions_dir, previous)
      restore_env(:bundled_extensions_dirs, previous_bundled)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "discovers enabled and disabled sources in stable order", %{root: root} do
    enabled_b = Path.join(root, "B Tool.ex")
    enabled_a = Path.join(root, "a-tool.ex")
    disabled = Path.join(root, "C Tool.ex.disabled")

    Enum.each([enabled_b, enabled_a, disabled], &File.write!(&1, "# probe\n"))

    assert Sources.enabled_files() == Enum.sort([enabled_a, enabled_b])
    assert Sources.disabled_files() == [disabled]
    assert Sources.owner(enabled_b) == "b_tool"
    assert Sources.disabled_owner(disabled) == "c_tool"
  end

  test "normalizes owners and groups unique expanded paths", %{root: root} do
    first = Path.join(root, "My---Tool.ex")
    equivalent = Path.join([root, ".", "My---Tool.ex"])
    colliding = Path.join(root, "my tool.ex")

    assert Sources.sanitize_owner("__My Tool!!__") == "my_tool"

    assert Sources.index_by_owner([first, equivalent, colliding]) == %{
             "my_tool" => Enum.sort([Path.expand(first), Path.expand(colliding)])
           }
  end

  test "discovers immutable bundled sources in configured directory order", %{root: root} do
    first_dir = Path.join(root, "first")
    second_dir = Path.join(root, "second")
    File.mkdir_p!(first_dir)
    File.mkdir_p!(second_dir)

    first = Path.join(first_dir, "bundled.ex")
    second = Path.join(second_dir, "other.ex")
    ignored = Path.join(first_dir, "README.md")
    Enum.each([first, second, ignored], &File.write!(&1, "# probe\n"))

    Application.put_env(:catalyst, :bundled_extensions_dirs, [first_dir, second_dir])

    assert Sources.bundled_files() == [first, second]
  end

  test "managed checks reject siblings and accept descendants", %{root: root} do
    nested = Path.join([root, "nested", "tool.ex"])
    sibling = Path.join(Path.dirname(root), Path.basename(root) <> "_other/tool.ex")

    assert Sources.managed?(nested)
    assert :ok = Sources.ensure_managed(nested)
    refute Sources.managed?(sibling)
    refute Sources.managed?(nil)
    assert {:error, :external_source} = Sources.ensure_managed(sibling)
  end

  test "find uses the supplied owner convention", %{root: root} do
    enabled = Path.join(root, "Some Tool.ex")
    disabled = enabled <> ".disabled"

    assert {:ok, ^enabled} = Sources.find([enabled], "some_tool", &Sources.owner/1)

    assert {:ok, ^disabled} =
             Sources.find([disabled], "some_tool", &Sources.disabled_owner/1)

    assert :error = Sources.find([enabled], "missing", &Sources.owner/1)
  end
end
