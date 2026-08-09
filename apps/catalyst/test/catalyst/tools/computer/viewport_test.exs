defmodule Catalyst.Tools.Computer.ViewportTest do
  # async: true is safe: the survival test uses a unique key against the
  # globally supervised table and kills only its own unnamed Helper; the
  # eviction test runs an isolated owner with its own table.
  use ExUnit.Case, async: true

  alias Catalyst.Tools.Computer.{Helper, Viewport}

  @viewport %{origin: {10, 20}, scale: 2.0, ratio: 0.5}

  test "the viewport table is owned by Viewport, supervised beside Helper" do
    children = Catalyst.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

    assert Catalyst.Tools.Computer.Viewport in children
    assert Catalyst.Tools.Computer.Helper in children
  end

  test "recorded geometry survives a Helper crash (stable table owner)" do
    key = {:viewport_survival, make_ref()}
    assert :ok = Viewport.put(key, @viewport)

    # A Helper dying — the regression: when the Helper owned the table, its
    # crash silently reset every session to the default viewport.
    helper =
      start_supervised!(
        {Helper, name: nil, helper_path: "/nonexistent/catalyst-input", helper_args: []},
        id: make_ref()
      )

    ref = Process.monitor(helper)
    Process.exit(helper, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    assert {:ok, @viewport} = Viewport.fetch(key)
  end

  test "the table is bounded: the oldest entries are evicted past max_entries" do
    table = :"viewport_evict_#{System.unique_integer([:positive])}"

    owner =
      start_supervised!(
        {Viewport, name: nil, table: table, max_entries: 3},
        id: make_ref()
      )

    for key <- [:a, :b, :c], do: assert(:ok = Viewport.put(owner, key, @viewport))

    # Re-putting refreshes recency, so :b (now the oldest) is evicted first.
    assert :ok = Viewport.put(owner, :a, @viewport)
    assert :ok = Viewport.put(owner, :d, @viewport)

    assert {:ok, @viewport} = Viewport.fetch_from(table, :a)
    assert :error = Viewport.fetch_from(table, :b)
    assert {:ok, @viewport} = Viewport.fetch_from(table, :c)
    assert {:ok, @viewport} = Viewport.fetch_from(table, :d)
  end

  test "a never-screenshotted session has no entry (coordinate actions fail closed)" do
    assert :error = Viewport.fetch({:never_screenshotted, make_ref()})
  end

  test "put degrades to :ok when the owner is down (no record; actions fail closed)" do
    table = :"viewport_down_#{System.unique_integer([:positive])}"
    id = make_ref()
    owner = start_supervised!({Viewport, name: nil, table: table}, id: id, restart: :temporary)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    assert :ok = Viewport.put(owner, :key, @viewport)
    assert :error = Viewport.fetch_from(table, :key)
  end
end
