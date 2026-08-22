defmodule CatalystWeb.RuntimeAssetController do
  @moduledoc "Serves immutable digest-addressed assets published outside the application bundle."

  use CatalystWeb, :controller

  alias CatalystWeb.RuntimeAssets

  @digest_format ~r/^[0-9a-f]{64}$/

  @doc "Serve the CSS file from a validated runtime asset generation, or return 404."
  @spec css(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def css(conn, %{"generation" => generation}), do: show(conn, generation, "assets/css/app.css")

  @doc "Serve the JavaScript file from a validated runtime asset generation, or return 404."
  @spec javascript(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def javascript(conn, %{"generation" => generation}),
    do: show(conn, generation, "assets/js/app.js")

  @doc "Serve one validated runtime ESM module, or return 404."
  @spec module(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def module(conn, %{"generation" => generation, "path" => path}) do
    case RuntimeAssets.module_file(generation, path) do
      {:ok, file} -> serve(conn, file)
      {:error, _reason} -> send_resp(conn, 404, "unknown runtime module")
    end
  end

  defp show(conn, generation, relative) do
    case asset_path(generation, relative) do
      {:ok, file} -> serve(conn, file)
      :error -> send_resp(conn, 404, "unknown runtime asset")
    end
  end

  defp asset_path(generation, relative) do
    with true <- Regex.match?(@digest_format, generation),
         file = Path.join(RuntimeAssets.generation_dir(generation), relative),
         true <- File.regular?(file) do
      {:ok, file}
    else
      _invalid_or_missing -> :error
    end
  end

  defp serve(conn, file) do
    conn
    |> put_resp_content_type(MIME.from_path(file), nil)
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> send_file(200, file)
  end
end
