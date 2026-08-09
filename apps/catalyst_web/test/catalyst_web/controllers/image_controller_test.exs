defmodule CatalystWeb.ImageControllerTest do
  # async: false — registers into the app's global CatalystWeb.UI.ImageStore.
  use CatalystWeb.ConnCase, async: false

  alias CatalystWeb.UI.ImageStore

  test "serves registered bytes with the stored MIME type and immutable caching", %{conn: conn} do
    bytes = :crypto.strong_rand_bytes(64)
    {:ok, digest} = ImageStore.register(Base.encode64(bytes), "image/png")

    conn = get(conn, ~p"/image/#{digest}")

    assert response(conn, 200) == bytes
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
  end

  test "an unknown digest 404s (evicted entries degrade to a broken image, not a crash)",
       %{conn: conn} do
    absent = Base.encode16(:crypto.hash(:sha256, "never registered"), case: :lower)

    assert conn |> get(~p"/image/#{absent}") |> response(404)
  end

  test "a malformed digest 404s without touching the store", %{conn: conn} do
    assert conn |> get(~p"/image/#{"not-a-digest"}") |> response(404)
    assert conn |> get(~p"/image/#{String.duplicate("Z", 64)}") |> response(404)
  end
end
