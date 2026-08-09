defmodule Catalyst.Tools.ListApps do
  @moduledoc """
  Enumerate the installed macOS applications, so the agent can pick a target for
  `open_app` / `applescript` by exact name instead of guessing.

  Two sources, merged and deduplicated:

    * the standard bundle directories — `/Applications`, `/System/Applications`,
      `~/Applications` — scanned one level deep so grouping folders like
      `/Applications/Utilities` are covered;
    * `mdfind "kMDItemContentType == 'com.apple.application-bundle'"` as a
      **supplement**, which finds bundles installed somewhere non-standard.
      Spotlight may be disabled, slow, or indexing; a failure or timeout there
      degrades to the directory scan rather than failing the tool.

  Two filters keep the listing to things a person can actually open. Helper
  bundles nested inside another `.app` are dropped everywhere. And the Spotlight
  supplement is restricted to bundles **outside** the system tree
  (`see supplemental?/1`): macOS carries several hundred agent bundles under
  `/System/Library` and `*.framework`, which would otherwise bury the real apps
  — and the directories where real system apps live are scanned directly
  anyway.
  """

  use Catalyst.Tools.Tool

  alias Catalyst.Tools.{Exec, Listing}

  @default_limit 300
  @max_limit 2000
  @mdfind_timeout_ms 5_000
  @mdfind_max_output_bytes 2 * 1024 * 1024
  @mdfind_query "kMDItemContentType == 'com.apple.application-bundle'"

  @typedoc "One installed application: its display name and bundle path."
  @type app :: %{name: String.t(), path: String.t()}

  @impl true
  def name, do: "list_apps"

  @impl true
  def execution_mode, do: :parallel

  @impl true
  def capabilities, do: [:computer_use]

  @impl true
  def description,
    do:
      "List the applications installed on this Mac (name and bundle path), from " <>
        "/Applications, /System/Applications and ~/Applications, supplemented by " <>
        "Spotlight. Use it to get an app's exact name before calling `open_app` or " <>
        "targeting it from `applescript` — an approximate name fails to launch. " <>
        "Pass `filter` to narrow the list by a case-insensitive substring."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "filter" => %{
          "type" => "string",
          "description" => "Case-insensitive substring matched against the app name"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Max apps to return (default #{@default_limit})",
          "minimum" => 1,
          "maximum" => @max_limit
        }
      }
    }
  end

  @doc "The bundle directories scanned directly, in listing order."
  @spec search_dirs() :: [String.t()]
  def search_dirs,
    do: ["/Applications", "/System/Applications", Path.expand("~/Applications")]

  @doc """
  Whether `path` names an application bundle.

      iex> Catalyst.Tools.ListApps.bundle?("/Applications/Safari.app")
      true

      iex> Catalyst.Tools.ListApps.bundle?("/Applications/Utilities")
      false
  """
  @spec bundle?(String.t()) :: boolean()
  def bundle?(path), do: String.ends_with?(path, ".app")

  @doc """
  Whether `path` is a helper bundle nested inside another application.

      iex> Catalyst.Tools.ListApps.nested?("/Applications/Xcode.app/Contents/Applications/Helper.app")
      true

      iex> Catalyst.Tools.ListApps.nested?("/Applications/Xcode.app")
      false
  """
  @spec nested?(String.t()) :: boolean()
  def nested?(path), do: path |> Path.dirname() |> String.contains?(".app/")

  @doc """
  Whether a Spotlight hit is worth adding to the directory scan.

  Only bundles outside the system tree qualify: `/System` and `/Library` hold
  hundreds of framework-embedded agents and background helpers that no user
  opens, and the system's real application directories are already scanned
  directly.

      iex> Catalyst.Tools.ListApps.supplemental?("/Users/me/dev/Build/My App.app")
      true

      iex> Catalyst.Tools.ListApps.supplemental?("/System/Library/CoreServices/AirPlayUIAgent.app")
      false

      iex> Catalyst.Tools.ListApps.supplemental?("/Library/Image Capture/Support/Helper.app")
      false
  """
  @spec supplemental?(String.t()) :: boolean()
  def supplemental?(path) do
    not (String.starts_with?(path, ["/System/", "/Library/"]) or
           String.contains?(path, ".framework/"))
  end

  @doc """
  Turn a bundle path into an `t:app/0` entry.

      iex> Catalyst.Tools.ListApps.entry("/System/Applications/Music.app")
      %{name: "Music", path: "/System/Applications/Music.app"}
  """
  @spec entry(String.t()) :: app()
  def entry(path), do: %{name: Path.basename(path, ".app"), path: path}

  @doc """
  Merge bundle paths from every source into a deduplicated, sorted app list.

  Non-bundles and nested helper bundles are dropped; duplicates collapse by
  path; the order is by display name (case-insensitively), then by path so two
  same-named apps in different directories keep a stable order.

      iex> Catalyst.Tools.ListApps.merge([["/Applications/b.app", "/Applications/A.app"], ["/Applications/A.app", "/tmp/x.txt"]])
      [%{name: "A", path: "/Applications/A.app"}, %{name: "b", path: "/Applications/b.app"}]
  """
  @spec merge([[String.t()]]) :: [app()]
  def merge(sources) do
    sources
    |> Enum.concat()
    |> Enum.filter(&(bundle?(&1) and not nested?(&1)))
    |> Enum.uniq()
    |> Enum.map(&entry/1)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.path})
  end

  @doc """
  Keep only the apps whose name contains `filter`, case-insensitively.

  A blank or missing filter keeps everything.

      iex> apps = [%{name: "Safari", path: "/Applications/Safari.app"}, %{name: "Mail", path: "/Applications/Mail.app"}]
      iex> Catalyst.Tools.ListApps.filter(apps, "saf")
      [%{name: "Safari", path: "/Applications/Safari.app"}]
      iex> Catalyst.Tools.ListApps.filter(apps, nil) == apps
      true
  """
  @spec filter([app()], term()) :: [app()]
  def filter(apps, filter) when is_binary(filter) and filter != "" do
    needle = String.downcase(filter)
    Enum.filter(apps, &String.contains?(String.downcase(&1.name), needle))
  end

  def filter(apps, _blank), do: apps

  @doc """
  Render app entries as one `name — path` line each.

      iex> Catalyst.Tools.ListApps.render([%{name: "Mail", path: "/Applications/Mail.app"}])
      "Mail — /Applications/Mail.app"
  """
  @spec render([app()]) :: String.t()
  def render(apps), do: Enum.map_join(apps, "\n", &"#{&1.name} — #{&1.path}")

  @impl true
  def execute(args, _ctx) when is_map(args) do
    limit = limit(args["limit"])

    apps =
      [scan_dirs(), spotlight()]
      |> merge()
      |> filter(args["filter"])

    shown = Enum.take(apps, limit)
    total = length(apps)

    {text, details} =
      shown
      |> render()
      |> Listing.render(
        count: length(shown),
        noun: "apps",
        limited?: total > limit,
        limit: limit,
        total: total
      )

    result(text, Map.put(details, :sources, length(search_dirs()) + 1))
  end

  # `File.ls/1` on a missing or unreadable directory is an expected outcome
  # (~/Applications frequently does not exist), not a failure of the tool.
  defp scan_dirs, do: Enum.flat_map(search_dirs(), &scan_dir/1)

  defp scan_dir(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.flat_map(names, &classify(Path.join(dir, &1)))
      {:error, _reason} -> []
    end
  end

  # One level deep: a `.app` is a leaf, anything else may be a grouping folder
  # (`/Applications/Utilities`) whose immediate children are bundles.
  defp classify(path) do
    case bundle?(path) do
      true -> [path]
      false -> child_bundles(path)
    end
  end

  defp child_bundles(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.map(&Path.join(dir, &1)) |> Enum.filter(&bundle?/1)
      {:error, _reason} -> []
    end
  end

  defp spotlight do
    case System.find_executable("mdfind") do
      nil -> []
      mdfind -> run_mdfind(mdfind)
    end
  end

  defp run_mdfind(mdfind) do
    case Exec.collect(mdfind, [@mdfind_query],
           timeout: @mdfind_timeout_ms,
           max_output_bytes: @mdfind_max_output_bytes
         ) do
      {:ok, %{out: out, status: 0}} ->
        out |> String.split("\n", trim: true) |> Enum.filter(&supplemental?/1)

      _unavailable ->
        []
    end
  end

  defp limit(value) when is_integer(value) and value > 0, do: min(value, @max_limit)
  defp limit(_other), do: @default_limit
end
