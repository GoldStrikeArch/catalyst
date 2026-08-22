defmodule CatalystWeb.RuntimeAssetsTest do
  use ExUnit.Case, async: false

  alias CatalystWeb.{Assets, RuntimeAssets}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "catalyst_runtime_assets_#{System.unique_integer([:positive])}"
      )

    seed = Path.join(tmp, "seed")
    workspace = Path.join(tmp, "workspace")
    root = Path.join(tmp, "runtime-assets")

    File.mkdir_p!(Path.join(seed, "assets/css"))
    File.mkdir_p!(Path.join(seed, "assets/js"))
    File.mkdir_p!(Path.join(seed, "assets/runtime/editor"))
    File.write!(Path.join(seed, "assets/css/app.css"), "seed css")
    File.write!(Path.join(seed, "assets/js/app.js"), "seed js")
    File.write!(Path.join(seed, "assets/runtime/editor/main.js"), "export default {}")

    original =
      for key <- [:asset_workspace_seed, :asset_workspace, :runtime_assets_root], into: %{} do
        {key, Application.get_env(:catalyst_web, key)}
      end

    Application.put_env(:catalyst_web, :asset_workspace_seed, seed)
    Application.put_env(:catalyst_web, :asset_workspace, workspace)
    Application.put_env(:catalyst_web, :runtime_assets_root, root)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:catalyst_web, key)
        {key, value} -> Application.put_env(:catalyst_web, key, value)
      end)

      File.rm_rf!(tmp)
    end)

    {:ok, workspace: workspace, root: root, seed: seed}
  end

  test "publishes a complete digest generation and exposes cache-busting URLs", %{root: root} do
    assert {:ok, %{generation: generation}} = RuntimeAssets.rebuild(&build("one", &1, &2))
    assert {:ok, ^generation} = RuntimeAssets.current_generation()
    assert String.length(generation) == 64

    assert File.read!(Path.join([root, "generations", generation, "assets/css/app.css"])) ==
             "one css"

    assert Assets.css_path() == "/runtime-assets/#{generation}/assets/css/app.css"
    assert Assets.js_path() == "/runtime-assets/#{generation}/assets/js/app.js"
  end

  test "a failed candidate leaves the previous generation active" do
    assert {:ok, %{generation: active}} = RuntimeAssets.rebuild(&build("good", &1, &2))

    failed = fn _source, output ->
      File.mkdir_p!(Path.join(output, "assets/css"))
      File.write!(Path.join(output, "assets/css/app.css"), "partial")
      {:error, :esbuild_failed}
    end

    assert {:error, :esbuild_failed} = RuntimeAssets.rebuild(failed)
    assert {:ok, ^active} = RuntimeAssets.current_generation()
  end

  test "identical output reuses the content generation" do
    assert {:ok, %{generation: first}} = RuntimeAssets.rebuild(&build("same", &1, &2))
    assert {:ok, %{generation: second}} = RuntimeAssets.rebuild(&build("same", &1, &2))

    assert second == first
  end

  test "publishes nested modules and includes them in the generation digest", %{
    workspace: workspace,
    root: root
  } do
    assert {:ok, %{generation: first}} = RuntimeAssets.rebuild(&build("same", &1, &2))
    module_url = "/runtime-assets/#{first}/modules/editor/main.js"

    assert {:ok, ^module_url} = RuntimeAssets.module_url("editor/main.js")

    assert File.read!(Path.join([root, "generations", first, "modules/editor/main.js"])) ==
             "export default {}"

    File.write!(
      Path.join(workspace, "assets/runtime/editor/main.js"),
      "export default { mounted() {} }"
    )

    assert {:ok, %{generation: second}} = RuntimeAssets.rebuild(&build("same", &1, &2))
    refute second == first
  end

  test "rejects unsafe module paths without changing the active generation", %{
    workspace: workspace
  } do
    assert {:ok, %{generation: active}} = RuntimeAssets.rebuild(&build("good", &1, &2))
    File.write!(Path.join(workspace, "assets/runtime/not-javascript.txt"), "no")

    assert {:error, {:invalid_runtime_module_path, ["not-javascript.txt"]}} =
             RuntimeAssets.rebuild(&build("candidate", &1, &2))

    assert {:ok, ^active} = RuntimeAssets.current_generation()
    assert {:error, :invalid_module_path} = RuntimeAssets.module_url("../editor/main.js")
    assert {:error, :invalid_module_path} = RuntimeAssets.module_url("editor/main.mjs")
  end

  test "rejects symlinked runtime modules", %{workspace: workspace} do
    assert {:ok, _root} = RuntimeAssets.ensure_workspace()
    outside = Path.join(Path.dirname(workspace), "outside.js")
    link = Path.join(workspace, "assets/runtime/escape.js")
    File.write!(outside, "export default 'outside'")
    File.ln_s!(outside, link)

    assert {:error, {:invalid_runtime_module_file, ["escape.js"]}} =
             RuntimeAssets.rebuild(&build("candidate", &1, &2))
  end

  test "rejects a symlinked runtime module root", %{workspace: workspace} do
    assert {:ok, _root} = RuntimeAssets.ensure_workspace()
    runtime = Path.join(workspace, "assets/runtime")
    outside = Path.join(Path.dirname(workspace), "outside-modules")
    File.rm_rf!(runtime)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "escape.js"), "export default 'outside'")
    File.ln_s!(outside, runtime)

    assert {:error, {:invalid_runtime_module_file, []}} =
             RuntimeAssets.rebuild(&build("candidate", &1, &2))
  end

  test "the packaged seed is copied once and never overwrites user edits", %{workspace: workspace} do
    assert {:ok, _published} = RuntimeAssets.rebuild(&build("first", &1, &2))
    css = Path.join(workspace, "assets/css/app.css")
    File.write!(css, "user edited css")

    checking_builder = fn source, output ->
      assert File.read!(source.css) == "user edited css"
      build("second", source, output)
    end

    assert {:ok, _published} = RuntimeAssets.rebuild(checking_builder)
    assert File.read!(css) == "user edited css"
  end

  test "a newer packaged seed updates unchanged files and preserves user edits", %{
    workspace: workspace,
    seed: seed
  } do
    assert {:ok, ^workspace} = RuntimeAssets.ensure_workspace()
    css = Path.join(workspace, "assets/css/app.css")
    js = Path.join(workspace, "assets/js/app.js")
    File.write!(css, "user edited css")

    File.write!(Path.join(seed, "assets/css/app.css"), "release two css")
    File.write!(Path.join(seed, "assets/js/app.js"), "release two js")
    File.write!(Path.join(seed, "assets/js/new-hook.js"), "new hook")

    assert {:ok, ^workspace} = RuntimeAssets.ensure_workspace()
    assert File.read!(css) == "user edited css"
    assert File.read!(js) == "release two js"
    assert File.read!(Path.join(workspace, "assets/js/new-hook.js")) == "new hook"
  end

  test "an unversioned modified workspace is reported instead of silently staying stale", %{
    workspace: workspace
  } do
    File.mkdir_p!(Path.join(workspace, "assets/css"))
    File.write!(Path.join(workspace, "assets/css/app.css"), "unknown user version")

    assert {:error, {:asset_workspace_unversioned, ^workspace}} =
             RuntimeAssets.ensure_workspace()
  end

  test "a rebuild removes staging trees abandoned by an earlier process crash", %{root: root} do
    abandoned = Path.join([root, ".staging", "abandoned"])
    File.mkdir_p!(abandoned)
    File.write!(Path.join(abandoned, "partial"), "partial")

    assert {:ok, _published} = RuntimeAssets.rebuild(&build("clean", &1, &2))
    refute File.exists?(abandoned)
  end

  test "missing or malformed current pointers use packaged assets", %{root: root} do
    assert Assets.css_path() == "/assets/css/app.css"
    assert Assets.js_path() == "/assets/js/app.js"
    assert {:error, :not_found} = RuntimeAssets.module_url("editor/main.js")
    assert {:error, :invalid_module_path} = RuntimeAssets.module_url("../editor/main.js")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "current"), "../../not-a-generation\n")

    assert Assets.css_path() == "/assets/css/app.css"
    assert Assets.js_path() == "/assets/js/app.js"
  end

  defp build(label, _source, output) do
    File.mkdir_p!(Path.join(output, "assets/css"))
    File.mkdir_p!(Path.join(output, "assets/js"))
    File.write!(Path.join(output, "assets/css/app.css"), "#{label} css")
    File.write!(Path.join(output, "assets/js/app.js"), "#{label} js")
    :ok
  end
end
