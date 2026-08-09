defmodule CatalystWeb.ImageController do
  @moduledoc """
  Serves transcript images registered in `CatalystWeb.UI.ImageStore` by
  content digest: `GET /image/:digest`.

  Digest-addressed content can never change, so hits carry
  `cache-control: public, max-age=31536000, immutable` — on a LiveView
  reconnect the browser re-requests nothing it has already cached, which is
  most of the reconnect win. A miss (malformed digest, unknown digest, or an
  entry evicted from the bounded store) is a plain 404: the transcript `<img>`
  degrades to its alt text and the bytes are re-registered the next time the
  owning message renders.
  """
  use CatalystWeb, :controller

  alias CatalystWeb.UI.ImageStore

  @digest_format ~r/^[0-9a-f]{64}$/

  @doc "Serve the stored image for a sha256 hex digest, or 404 on any miss."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"digest" => digest}) do
    case lookup(digest) do
      {:ok, {mime, bytes}} -> serve(conn, mime, bytes)
      :error -> send_resp(conn, 404, "unknown or evicted image digest")
    end
  end

  defp lookup(digest) do
    case Regex.match?(@digest_format, digest) do
      true -> ImageStore.fetch(digest)
      false -> :error
    end
  end

  defp serve(conn, mime, bytes) do
    conn
    |> put_resp_content_type(mime, nil)
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> send_resp(200, bytes)
  end
end
