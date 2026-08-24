defmodule Catalyst.Tools.OpenApp do
  @moduledoc """
  Launch an application, open a file or URL, or reveal a path in Finder, via
  `open(1)`.

  `open` needs **no TCC grant** — it asks Launch Services to open something, it
  does not synthesize input or read the screen — so this is the cheapest way to
  get an app in front of the user before driving it with `applescript`.

  `argv/2` is pure and holds the whole flag mapping; `execute/2` only resolves
  the path against the session cwd and shells out.
  """

  use Catalyst.Tools.Tool

  alias Catalyst.Tools.{Exec, Paths, Truncate}

  @timeout_ms 30_000

  @impl true
  def name, do: "open_app"

  @impl true
  def execution_mode, do: :sequential

  @impl true
  def capabilities, do: [:computer_use]

  @impl true
  def description,
    do:
      "Open something with macOS `open(1)`: launch an app by name (`app`) or bundle id " <>
        "(`bundle_id`), open a file or folder (`path`), open a URL in the default browser " <>
        "(`url`), or reveal a path in Finder (`reveal`). Give an `app` together with a " <>
        "`path` to open that file in that specific app. Returns as soon as the open " <>
        "request is handed off — it does not wait for the app to finish launching, so " <>
        "give it a moment (or poll with `applescript`) before driving the app. " <>
        "This is the right way to get an app on screen; prefer it, plus `applescript` " <>
        "menu targeting, over hunting for a Dock icon in a screenshot."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "app" => %{
          "type" => "string",
          "description" => "Application name or path, e.g. \"Safari\" (open -a)"
        },
        "bundle_id" => %{
          "type" => "string",
          "description" => "Bundle identifier, e.g. \"com.apple.Safari\" (open -b)"
        },
        "path" => %{
          "type" => "string",
          "description" => "File or folder to open; relative paths resolve against the cwd"
        },
        "url" => %{
          "type" => "string",
          "description" => "URL to open, e.g. \"https://example.com\""
        },
        "reveal" => %{
          "type" => "boolean",
          "description" => "Reveal `path` in Finder instead of opening it (open -R)"
        },
        "args" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Arguments passed to the launched app (open --args)"
        }
      }
    }
  end

  @doc """
  Build the `open(1)` argument list, or explain why the request is unusable.

  `path` is already resolved to an absolute path by the caller. Errors:
  `{:error, :no_target}` when nothing was asked for, `{:error, :reveal_needs_path}`
  when `reveal` has nothing to reveal, and `{:error, {:bad_args, value}}` when
  `args` is not a list of strings.

      iex> Catalyst.Tools.OpenApp.argv(%{"app" => "Safari"})
      {:ok, ["-a", "Safari"]}

      iex> Catalyst.Tools.OpenApp.argv(%{"bundle_id" => "com.apple.Safari", "url" => "https://example.com"})
      {:ok, ["-b", "com.apple.Safari", "https://example.com"]}

      iex> Catalyst.Tools.OpenApp.argv(%{"path" => "/tmp/notes.txt", "reveal" => true})
      {:ok, ["-R", "/tmp/notes.txt"]}

      iex> Catalyst.Tools.OpenApp.argv(%{"app" => "Preview", "args" => ["--headless"]})
      {:ok, ["-a", "Preview", "--args", "--headless"]}

      iex> Catalyst.Tools.OpenApp.argv(%{})
      {:error, :no_target}

      iex> Catalyst.Tools.OpenApp.argv(%{"app" => "Finder", "reveal" => true})
      {:error, :reveal_needs_path}
  """
  @spec argv(map()) :: {:ok, [String.t()]} | {:error, term()}
  def argv(args) when is_map(args) do
    with {:ok, targets} <- targets(args),
         {:ok, passthrough} <- passthrough(args["args"]) do
      {:ok, flags(args) ++ targets ++ passthrough}
    end
  end

  defp flags(args) do
    [
      opt("-a", args["app"]),
      opt("-b", args["bundle_id"]),
      reveal_flag(args["reveal"])
    ]
    |> List.flatten()
  end

  defp opt(_flag, nil), do: []
  defp opt(_flag, ""), do: []
  defp opt(flag, value) when is_binary(value), do: [flag, value]

  defp reveal_flag(true), do: ["-R"]
  defp reveal_flag(_other), do: []

  # `open` has no `--` separator, so a positional argument beginning with `-`
  # would be read as a flag. Paths are absolute by the time they arrive here;
  # a URL starting with `-` is not a URL.
  defp targets(args) do
    positional = Enum.reject([args["path"], args["url"]], &blank?/1)

    cond do
      Enum.any?(positional, &String.starts_with?(&1, "-")) ->
        {:error, {:bad_target, Enum.find(positional, &String.starts_with?(&1, "-"))}}

      args["reveal"] == true and blank?(args["path"]) ->
        {:error, :reveal_needs_path}

      positional == [] and blank?(args["app"]) and blank?(args["bundle_id"]) ->
        {:error, :no_target}

      true ->
        {:ok, positional}
    end
  end

  defp passthrough(nil), do: {:ok, []}
  defp passthrough([]), do: {:ok, []}

  defp passthrough(args) when is_list(args) do
    case Enum.all?(args, &is_binary/1) do
      true -> {:ok, ["--args" | args]}
      false -> {:error, {:bad_args, args}}
    end
  end

  defp passthrough(args), do: {:error, {:bad_args, args}}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: false
  defp blank?(_other), do: true

  @impl true
  def execute(args, ctx) when is_map(args) do
    args = resolve_path(args, ctx.cwd)

    case argv(args) do
      {:ok, argv} -> run(argv)
      {:error, reason} -> raise error_message(reason)
    end
  end

  defp resolve_path(%{"path" => path} = args, cwd) when is_binary(path) and path != "",
    do: %{args | "path" => Paths.resolve(path, cwd)}

  defp resolve_path(args, _cwd), do: args

  defp run(argv) do
    case Exec.collect(open_binary(), argv, timeout: @timeout_ms) do
      {:ok, %{out: out, status: 0}} ->
        result(summary(argv, out), %{exit_status: 0, argv: argv})

      {:ok, %{out: out, status: status}} ->
        raise "open failed (status #{status}): #{String.trim(scrub(out))}"

      {:error, :timeout} ->
        raise "open timed out after #{div(@timeout_ms, 1000)}s"

      {:error, reason} ->
        raise "open failed: #{inspect(reason)}"
    end
  end

  defp summary(argv, out) do
    header = "opened: open " <> Enum.join(argv, " ")

    case String.trim(scrub(out)) do
      "" -> header
      trimmed -> header <> "\n" <> trimmed
    end
  end

  defp scrub(out), do: out |> Truncate.scrub_utf8() |> String.slice(0, 2000)

  defp error_message(:no_target),
    do: "open_app needs at least one of: app, bundle_id, path, url"

  defp error_message(:reveal_needs_path), do: "open_app `reveal` requires a `path`"

  defp error_message({:bad_target, value}),
    do: "open_app target #{inspect(value)} would be read as a flag by open(1)"

  defp error_message({:bad_args, value}),
    do: "open_app `args` must be a list of strings, got #{inspect(value)}"

  defp open_binary, do: System.find_executable("open") || "/usr/bin/open"
end
