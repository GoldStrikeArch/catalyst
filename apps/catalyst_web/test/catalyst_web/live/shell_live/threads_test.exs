defmodule CatalystWeb.ShellLive.ThreadsTest do
  use ExUnit.Case, async: true

  alias CatalystWeb.ShellLive.Threads

  defp entry(id, cwd, created_at, last_used_at),
    do: %{id: id, cwd: cwd, created_at: created_at, last_used_at: last_used_at, title: id}

  # Catalog order is most-recently-used first; the sidebar must not follow it.
  defp entries do
    [
      entry("umb-new", "/w/catalyst_umbrella", "2026-08-27T10:00:00Z", "2026-08-27T12:00:00Z"),
      entry("top-1", "/w/topcoat", "2026-08-26T09:00:00Z", "2026-08-27T11:00:00Z"),
      entry("umb-old", "/w/catalyst_umbrella", "2026-08-25T10:00:00Z", "2026-08-27T10:30:00Z"),
      entry("agent-1", "/w/agent-2", "2026-08-20T10:00:00Z", "2026-08-20T10:00:00Z")
    ]
  end

  test "projects sort by name and threads newest-first by creation, regardless of recency" do
    %{projects: projects} = Threads.project(entries(), nil)

    assert Enum.map(projects, & &1.label) == ["agent-2", "catalyst_umbrella", "topcoat"]

    umbrella = Enum.find(projects, &(&1.label == "catalyst_umbrella"))
    assert Enum.map(umbrella.threads, & &1.id) == ["umb-new", "umb-old"]
  end

  test "the focused thread never changes the order" do
    order = fn current -> Threads.project(entries(), current) |> ids() end

    assert order.("top-1") == order.(nil)
    assert order.("umb-old") == order.(nil)
    assert order.("agent-1") == order.(nil)

    %{projects: projects} = Threads.project(entries(), "umb-old")
    assert Enum.find(projects, & &1.current?).label == "catalyst_umbrella"

    assert Enum.find(projects, & &1.current?).threads
           |> Enum.find(& &1.current?)
           |> Map.fetch!(:id) == "umb-old"
  end

  test "same-named projects in different places keep a stable relative order" do
    entries = [
      entry("z2", "/work/zed", "2026-08-27T10:00:00Z", "2026-08-27T12:00:00Z"),
      entry("z1", "/oss/zed", "2026-08-27T09:00:00Z", "2026-08-27T09:00:00Z")
    ]

    assert Threads.project(entries, "z2") |> ids() == Threads.project(entries, "z1") |> ids()
    assert Enum.map(Threads.project(entries, nil).projects, & &1.cwd) == ["/oss/zed", "/work/zed"]
  end

  defp ids(%{projects: projects}),
    do: Enum.map(projects, fn project -> {project.cwd, Enum.map(project.threads, & &1.id)} end)
end
