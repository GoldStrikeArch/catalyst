defmodule Catalyst.Tools.ListAgentsTest do
  use ExUnit.Case, async: false

  alias Catalyst.Content
  alias Catalyst.Tools.ListAgents

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "catalyst_agents_#{System.unique_integer([:positive, :monotonic])}"
      )

    previous = Application.fetch_env(:catalyst, :agents_dir)
    Application.put_env(:catalyst, :agents_dir, dir)
    File.mkdir_p!(dir)

    on_exit(fn ->
      restore_env(previous)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "discovers only safe markdown basenames and previews the first nonblank line", %{dir: dir} do
    valid = Path.join(dir, "review_agent.md")
    File.write!(valid, "\n  \nReview changes for correctness.\nMore instructions.\n")
    File.write!(Path.join(dir, "bad name.md"), "must not appear")
    File.write!(Path.join(dir, String.duplicate("x", 65) <> ".md"), "too long")
    File.write!(Path.join(dir, "notes.txt"), "not markdown")

    assert {:ok, [%{name: "review_agent", path: ^valid, preview: preview}]} =
             ListAgents.list()

    assert preview == "Review changes for correctness."

    result = ListAgents.execute(%{}, %{cwd: dir})
    assert Content.text_of(result.content) =~ "review_agent"
    assert result.details.agents == [%{name: "review_agent", path: valid, preview: preview}]
  end

  test "fetch validates before resolving and reads prompt edits fresh", %{dir: dir} do
    path = Path.join(dir, "fresh.md")
    File.write!(path, "first prompt")

    assert {:error, {:invalid_agent_name, "../fresh"}} = ListAgents.fetch("../fresh")
    assert {:ok, %{prompt: "first prompt"}} = ListAgents.fetch("fresh")

    File.write!(path, "second prompt")
    assert {:ok, %{prompt: "second prompt"}} = ListAgents.fetch("fresh")
  end

  test "missing directories are an empty discovery result and blank prompts cannot spawn", %{
    dir: dir
  } do
    File.rm_rf!(dir)
    assert {:ok, []} = ListAgents.list()

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "blank.md"), " \n\t\n")
    assert {:error, {:blank_agent_prompt, "blank"}} = ListAgents.fetch("blank")
  end

  defp restore_env({:ok, value}), do: Application.put_env(:catalyst, :agents_dir, value)
  defp restore_env(:error), do: Application.delete_env(:catalyst, :agents_dir)
end
