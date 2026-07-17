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

  def run(["tools" | _]) do
    IO.puts("registered tools: " <> Enum.join(Enum.sort(Catalyst.Extensions.names()), ", "))
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
        ctx = %{cwd: ".", call_id: "x", report: fn _ -> :ok end}
        out = Catalyst.Extensions.fetch("cli_shout").execute(%{"text" => "packaged hot-load works"}, ctx)
        IO.puts("called the new tool -> " <> (out.content |> hd() |> Map.get(:text)))
        IO.puts("OK: a self-contained binary loaded NEW code into the running VM.")

      {:error, reason} ->
        IO.puts("FAILED: #{inspect(reason)}")
    end
  end

  def run(_), do: IO.puts("usage: catalyst [tools|selftest]")
end
