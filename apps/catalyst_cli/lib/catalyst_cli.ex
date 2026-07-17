defmodule CatalystCli do
  @moduledoc """
  A tiny headless entrypoint used to package Catalyst's core as a self-contained
  Burrito binary — and to prove the key claim: a packaged binary can still
  compile and load an extension at runtime (because the Elixir compiler ships in
  the release).
  """

  @shout ~S'''
  defmodule Catalyst.Ext.CliShout do
    use Catalyst.Tools.Tool
    @impl true
    def name, do: "cli_shout"
    @impl true
    def description, do: "Uppercases text."
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}
    @impl true
    def execute(%{"text" => t}, _ctx), do: result(String.upcase(t))
  end
  '''

  @doc """
  Run a CLI command. Returns `:ok` on success and `:error` on failure so the
  caller (`CatalystCli.Application.run_and_halt/0`) can set a meaningful process
  exit code for scripts/CI.
  """
  @spec run([String.t()]) :: :ok | :error
  def run(["tools" | _]) do
    IO.puts("registered tools: " <> Enum.join(Enum.sort(Catalyst.Extensions.names()), ", "))
    :ok
  end

  def run(["selftest" | _]) do
    IO.puts("== Catalyst packaged self-develop test ==")
    dir = Catalyst.Extensions.dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "cli_shout.ex")
    File.write!(path, @shout)

    case Catalyst.Extensions.load_file(path) do
      {:ok, mods} ->
        IO.puts("compiled + loaded at runtime: #{inspect(mods)}")
        run_loaded_tool()

      {:error, reason} ->
        IO.puts("FAILED: #{inspect(reason)}")
        :error
    end
  end

  def run(argv) do
    IO.puts("usage: catalyst [tools|selftest] (got: #{inspect(argv)})")
    :error
  end

  # Exercise the just-loaded tool, guarding a missing registration or an
  # unexpected result shape so a broken hot-load reports failure instead of
  # crashing with a MatchError/UndefinedFunctionError.
  defp run_loaded_tool do
    ctx = %{cwd: ".", call_id: "x", report: fn _ -> :ok end}

    with tool when not is_nil(tool) <- Catalyst.Extensions.fetch("cli_shout"),
         %{content: content} <- tool.execute(%{"text" => "packaged hot-load works"}, ctx),
         text when is_binary(text) <- Catalyst.Content.text_of(content) do
      IO.puts("called the new tool -> " <> text)
      IO.puts("OK: a self-contained binary loaded NEW code into the running VM.")
      :ok
    else
      other ->
        IO.puts("FAILED: tool loaded but did not run as expected (#{inspect(other)})")
        :error
    end
  end
end
