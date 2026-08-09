defmodule CatalystWeb.UI.ImageStore do
  @moduledoc """
  Bounded, digest-addressed store for transcript image bytes.

  Transcript images (`Catalyst.Content.Image`) used to be rendered as inline
  base64 data URIs. Reattaching to a session re-streams every persisted
  message, so a screenshot-heavy computer-use session re-embedded every
  capture it ever took on every reconnect — well over 100MB of HTML for an
  ordinary 100-screenshot session, over a LiveView websocket into a webview.
  `CatalystWeb.UI.MessageRenderer` now registers the decoded bytes here and
  emits a small `/image/:digest` reference; `CatalystWeb.ImageController`
  serves the bytes with immutable cache headers, so a reconnecting client
  re-downloads nothing it already has cached.

  Modeled on `Catalyst.Tools.Computer.Viewport`: a public named ETS table
  owned by a small supervised GenServer that exists purely to be a stable
  table owner and the single writer, keeping eviction race-free. Reads and
  digest computation run in the caller; only inserts and recency touches go
  through the owner.

  The table is **bounded**: by entry count (default 256), by total decoded
  bytes (default 64MB), and per image (8MB, refused outright). Writes stamp a
  monotonic counter and re-registering an existing digest refreshes its stamp,
  so eviction drops the least recently rendered images first. A bounded store
  evicts: an evicted digest 404s from the controller and the transcript's
  `<img>` degrades to its alt text — the LiveView never crashes — while the
  next render of the owning message re-registers the bytes, and clients that
  fetched the image before typically still hold it under the immutable cache
  header.

  Keys are lowercase hex sha256 digests of the decoded bytes:
  content-addressed, so identical captures dedupe across messages, and
  unguessable without already holding the content — which is why entries are
  not additionally scoped per session (the endpoint is single-user, and
  packaged desktop builds lock it to the webview via `Desktop.Auth`).

  Only raster image MIME types are accepted (#{inspect(~w(image/png image/jpeg image/gif image/webp))}).
  The controller reflects the stored MIME type verbatim, so storing e.g.
  `image/svg+xml` or `text/html` would let tool-supplied content execute
  same-origin on direct navigation; such registrations return `:error`.
  """

  use GenServer

  @table :catalyst_web_image_store
  @default_max_entries 256
  @default_max_bytes 64 * 1024 * 1024
  @max_image_bytes 8 * 1024 * 1024
  @allowed_mime_types ~w(image/png image/jpeg image/gif image/webp)

  @typedoc "Lowercase hex sha256 digest of the decoded image bytes."
  @type digest :: String.t()

  @doc """
  Start the image table owner. Options: `:name` (default
  `#{inspect(__MODULE__)}`, `nil` for an unnamed test instance), `:table`
  (ETS table name, default `#{inspect(@table)}`), `:max_entries` (default
  #{@default_max_entries}), `:max_bytes` (total decoded-byte bound, default
  #{@default_max_bytes}).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Register a base64-encoded image and return its content digest.

  Decodes once, stores the raw bytes, and dedupes by digest (re-registration
  only refreshes recency). Returns `:error` for invalid base64, a
  non-raster/unknown MIME type, or an image over the per-image byte cap.

  The owner being down degrades rather than raises: the digest is still
  returned, the bytes are simply not stored, and the controller answers 404
  until a later render re-registers them.
  """
  @spec register(String.t(), String.t()) :: {:ok, digest()} | :error
  def register(data_base64, mime_type), do: register(__MODULE__, @table, data_base64, mime_type)

  @doc "Register through a specific owner and table (test instances)."
  @spec register(GenServer.server(), atom(), String.t(), String.t()) :: {:ok, digest()} | :error
  def register(server, table, data_base64, mime_type)
      when is_binary(data_base64) and is_binary(mime_type) do
    with true <- mime_type in @allowed_mime_types,
         {:ok, bytes} <- Base.decode64(data_base64),
         true <- byte_size(bytes) <= @max_image_bytes do
      {:ok, store(server, table, sha256_hex(bytes), mime_type, bytes)}
    else
      _invalid -> :error
    end
  end

  @doc "The stored MIME type and bytes for a digest."
  @spec fetch(digest()) :: {:ok, {String.t(), binary()}} | :error
  def fetch(digest), do: fetch_from(@table, digest)

  @doc "The stored MIME type and bytes from a specific table (test instances)."
  @spec fetch_from(atom(), digest()) :: {:ok, {String.t(), binary()}} | :error
  def fetch_from(table, digest) do
    case :ets.whereis(table) do
      :undefined -> :error
      _tid -> lookup(table, digest)
    end
  end

  defp lookup(table, digest) do
    case :ets.lookup(table, digest) do
      [{^digest, mime, bytes, _stamp}] -> {:ok, {mime, bytes}}
      [] -> :error
    end
  end

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  # New digests insert synchronously (the call also runs eviction); an already
  # stored digest only needs its recency refreshed, so skip re-sending the
  # bytes and touch asynchronously. Losing a touch or an insert (owner down,
  # eviction race) degrades to a controller 404 → alt-text placeholder.
  defp store(server, table, digest, mime, bytes) do
    case stored?(table, digest) do
      true -> GenServer.cast(server, {:touch, digest})
      false -> GenServer.call(server, {:put, digest, mime, bytes})
    end

    digest
  catch
    :exit, _owner_down -> digest
  end

  defp stored?(table, digest) do
    case :ets.whereis(table) do
      :undefined -> false
      _tid -> :ets.member(table, digest)
    end
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    table =
      opts
      |> Keyword.get(:table, @table)
      |> :ets.new([:named_table, :public, :set, read_concurrency: true])

    {:ok,
     %{
       table: table,
       bytes: 0,
       max_entries: Keyword.get(opts, :max_entries, @default_max_entries),
       max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
     }}
  end

  @impl true
  def handle_call({:put, digest, mime, bytes}, _from, state) do
    {:reply, :ok, state |> insert(digest, mime, bytes) |> evict()}
  end

  @impl true
  def handle_cast({:touch, digest}, state) do
    :ets.update_element(state.table, digest, {4, stamp()})
    {:noreply, state}
  end

  # insert_new keeps the byte accounting exact when two renders race the same
  # new digest to the owner: only the first one counts.
  defp insert(state, digest, mime, bytes) do
    case :ets.insert_new(state.table, {digest, mime, bytes, stamp()}) do
      true ->
        %{state | bytes: state.bytes + byte_size(bytes)}

      false ->
        :ets.update_element(state.table, digest, {4, stamp()})
        state
    end
  end

  defp evict(state) do
    case over_bound?(state) do
      true -> drop_oldest(state, oldest_first(state.table))
      false -> state
    end
  end

  defp over_bound?(state) do
    :ets.info(state.table, :size) > state.max_entries or state.bytes > state.max_bytes
  end

  defp oldest_first(table) do
    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_digest, _mime, _bytes, stamp} -> stamp end)
  end

  defp drop_oldest(state, [{digest, _mime, bytes, _stamp} | rest]) do
    case over_bound?(state) do
      true ->
        :ets.delete(state.table, digest)
        drop_oldest(%{state | bytes: state.bytes - byte_size(bytes)}, rest)

      false ->
        state
    end
  end

  defp drop_oldest(state, []), do: state

  defp stamp, do: :erlang.unique_integer([:monotonic])
end
