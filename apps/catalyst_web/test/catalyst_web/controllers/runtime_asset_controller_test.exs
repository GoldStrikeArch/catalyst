defmodule CatalystWeb.RuntimeAssetControllerTest do
  use CatalystWeb.ConnCase, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "catalyst_runtime_asset_controller_#{System.unique_integer([:positive])}"
      )

    original = Application.get_env(:catalyst_web, :runtime_assets_root)
    Application.put_env(:catalyst_web, :runtime_assets_root, root)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:catalyst_web, :runtime_assets_root)
        value -> Application.put_env(:catalyst_web, :runtime_assets_root, value)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "serves immutable files from a digest generation", %{conn: conn, root: root} do
    generation = String.duplicate("a", 64)
    file = Path.join([root, "generations", generation, "assets/js/app.js"])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "export default 1")

    conn = get(conn, "/runtime-assets/#{generation}/assets/js/app.js")

    assert response(conn, 200) == "export default 1"
    assert get_resp_header(conn, "content-type") == ["text/javascript"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "serves validated nested runtime modules", %{conn: conn, root: root} do
    generation = String.duplicate("d", 64)
    file = Path.join([root, "generations", generation, "modules/editor/main.js"])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "export default { mounted() {} }")

    conn = get(conn, "/runtime-assets/#{generation}/modules/editor/main.js")

    assert response(conn, 200) == "export default { mounted() {} }"
    assert get_resp_header(conn, "content-type") == ["text/javascript"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "rejects malformed and unsafe runtime module paths", %{conn: conn, root: root} do
    generation = String.duplicate("e", 64)
    modules = Path.join([root, "generations", generation, "modules"])
    File.mkdir_p!(modules)
    File.write!(Path.join(modules, "readme.txt"), "no")

    assert conn
           |> get("/runtime-assets/#{generation}/modules/readme.txt")
           |> response(404)

    assert build_conn()
           |> get("/runtime-assets/not-a-digest/modules/editor/main.js")
           |> response(404)

    assert build_conn()
           |> get("/runtime-assets/#{generation}/modules/%2e%2e/assets/js/app.js")
           |> response(404)
  end

  test "rejects malformed generations and missing files", %{conn: conn} do
    generation = String.duplicate("b", 64)

    assert conn |> get("/runtime-assets/not-a-digest/assets/js/app.js") |> response(404)

    assert build_conn()
           |> get("/runtime-assets/#{generation}/assets/js/app.js")
           |> response(404)
  end

  test "the root layout falls back to packaged assets then selects the active generation", %{
    conn: conn,
    root: root
  } do
    fallback = conn |> get("/") |> html_response(200)
    assert fallback =~ ~s(href="/assets/css/app.css")
    assert fallback =~ ~s(src="/assets/js/app.js")

    generation = String.duplicate("c", 64)
    css = Path.join([root, "generations", generation, "assets/css/app.css"])
    js = Path.join([root, "generations", generation, "assets/js/app.js"])
    File.mkdir_p!(Path.dirname(css))
    File.mkdir_p!(Path.dirname(js))
    File.write!(css, "body {}")
    File.write!(js, "export default 1")
    File.write!(Path.join(root, "current"), generation <> "\n")

    active = build_conn() |> get("/") |> html_response(200)
    assert active =~ ~s(href="/runtime-assets/#{generation}/assets/css/app.css")
    assert active =~ ~s(src="/runtime-assets/#{generation}/assets/js/app.js")
  end
end
