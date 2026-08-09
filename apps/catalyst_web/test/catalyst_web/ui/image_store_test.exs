defmodule CatalystWeb.UI.ImageStoreTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.UI.ImageStore

  @mime "image/png"

  defp start_store!(opts) do
    table = :"image_store_test_#{System.unique_integer([:positive])}"
    server = start_supervised!({ImageStore, [name: nil, table: table] ++ opts})
    {server, table}
  end

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp register!(server, table, bytes) do
    {:ok, digest} = ImageStore.register(server, table, Base.encode64(bytes), @mime)
    digest
  end

  test "registers decoded bytes under their sha256 digest" do
    {server, table} = start_store!([])
    bytes = <<1, 2, 3, 4>>

    assert {:ok, digest} = ImageStore.register(server, table, Base.encode64(bytes), @mime)
    assert digest == sha256_hex(bytes)
    assert ImageStore.fetch_from(table, digest) == {:ok, {@mime, bytes}}
  end

  test "identical content registered twice stays a single entry" do
    {server, table} = start_store!([])

    digest = register!(server, table, <<7, 7, 7>>)
    assert register!(server, table, <<7, 7, 7>>) == digest

    # The touch on re-registration is async; sync before counting entries.
    _ = :sys.get_state(server)
    assert :ets.info(table, :size) == 1
  end

  test "rejects invalid base64, non-raster MIME types, and oversized images" do
    {server, table} = start_store!([])
    encoded = Base.encode64(<<1>>)

    assert ImageStore.register(server, table, "%%%not-base64%%%", @mime) == :error
    assert ImageStore.register(server, table, encoded, "text/html") == :error
    assert ImageStore.register(server, table, encoded, "image/svg+xml") == :error

    oversized = :binary.copy(<<0>>, 8 * 1024 * 1024 + 1)
    assert ImageStore.register(server, table, Base.encode64(oversized), @mime) == :error

    assert :ets.info(table, :size) == 0
  end

  test "an unknown digest is a miss" do
    {_server, table} = start_store!([])
    assert ImageStore.fetch_from(table, sha256_hex("absent")) == :error
  end

  test "bounds the entry count by evicting the least recently registered" do
    {server, table} = start_store!(max_entries: 2)

    a = register!(server, table, <<1>>)
    b = register!(server, table, <<2>>)
    c = register!(server, table, <<3>>)

    assert ImageStore.fetch_from(table, a) == :error
    assert ImageStore.fetch_from(table, b) == {:ok, {@mime, <<2>>}}
    assert ImageStore.fetch_from(table, c) == {:ok, {@mime, <<3>>}}
  end

  test "re-registering refreshes recency so warm entries survive eviction" do
    {server, table} = start_store!(max_entries: 2)

    a = register!(server, table, <<1>>)
    b = register!(server, table, <<2>>)

    # Touch a (async cast) and let the owner process it before overflowing.
    assert register!(server, table, <<1>>) == a
    _ = :sys.get_state(server)

    c = register!(server, table, <<3>>)

    assert ImageStore.fetch_from(table, a) == {:ok, {@mime, <<1>>}}
    assert ImageStore.fetch_from(table, b) == :error
    assert ImageStore.fetch_from(table, c) == {:ok, {@mime, <<3>>}}
  end

  test "bounds total stored bytes, not just entry count" do
    {server, table} = start_store!(max_bytes: 8)

    a = register!(server, table, <<1, 1, 1, 1, 1>>)
    b = register!(server, table, <<2, 2, 2, 2, 2>>)

    assert ImageStore.fetch_from(table, a) == :error
    assert ImageStore.fetch_from(table, b) == {:ok, {@mime, <<2, 2, 2, 2, 2>>}}
  end

  test "registering against a stopped owner degrades to a miss, not a raise" do
    table = :"image_store_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({ImageStore, name: nil, table: table})
    # stop_supervised!/1 terminates synchronously; the owner and its table are gone.
    stop_supervised!(ImageStore)

    assert {:ok, digest} = ImageStore.register(pid, table, Base.encode64(<<5>>), @mime)
    assert ImageStore.fetch_from(table, digest) == :error
  end
end
