defmodule CatalystWeb.ShellLive.Threads do
  @moduledoc """
  Projects the persisted session catalog into the shell sidebar.

  A **project** is a working directory. A **thread** is one catalog entry
  (a `Session.Server`). Live flags come from the process registry.
  """

  alias Catalyst.Session.{Catalog, Manager}

  @type thread :: %{
          id: String.t(),
          cwd: String.t(),
          title: String.t(),
          current?: boolean(),
          live?: boolean()
        }

  @type project :: %{
          cwd: String.t(),
          id: String.t(),
          label: String.t(),
          current?: boolean(),
          threads: [thread()]
        }

  @type sidebar :: %{projects: [project()]}

  @doc """
  Group catalog entries by cwd and attach live flags.

  The order is stable across focus and use: projects sort by name (then path)
  and threads newest-first by creation — never by recency or by which thread
  is current, so switching threads doesn't reshuffle the list under the cursor.
  """
  @spec project([Catalog.entry()], String.t() | nil) :: sidebar()
  def project(entries, current_id) when is_list(entries) do
    live = live_ids()

    projects =
      entries
      |> Enum.group_by(& &1.cwd)
      |> Enum.map(fn {cwd, threads} ->
        rows =
          threads
          |> Enum.sort_by(&{&1.created_at, &1.id}, :desc)
          |> Enum.map(&thread_row(&1, current_id, live))

        %{
          cwd: cwd,
          id: project_dom_id(cwd),
          label: project_label(cwd),
          current?: Enum.any?(rows, & &1.current?),
          threads: rows
        }
      end)
      |> Enum.sort_by(fn project -> {String.downcase(project.label), project.cwd} end)

    %{projects: projects}
  end

  defp thread_row(entry, current_id, live) do
    %{
      id: entry.id,
      cwd: entry.cwd,
      title: Catalog.display_title(entry),
      current?: entry.id == current_id,
      live?: MapSet.member?(live, entry.id)
    }
  end

  defp live_ids do
    MapSet.new(Manager.list_live(), fn {id, _pid} -> id end)
  end

  defp project_label(cwd) when is_binary(cwd) do
    case Path.basename(cwd) do
      "" -> cwd
      name -> name
    end
  end

  defp project_dom_id(cwd) do
    hash =
      :sha256
      |> :crypto.hash(cwd)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "project-#{hash}"
  end
end
