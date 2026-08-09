defmodule Catalyst.Tools.ListAppsTest do
  use ExUnit.Case, async: true

  doctest Catalyst.Tools.ListApps

  alias Catalyst.Content
  alias Catalyst.Tools.ListApps

  @darwin? :os.type() == {:unix, :darwin}

  describe "registration" do
    test "is parallel-safe and gated behind computer use" do
      assert ListApps.name() == "list_apps"
      assert ListApps.execution_mode() == :parallel
      assert ListApps.capabilities() == [:computer_use]
    end

    test "searches the three standard bundle directories" do
      assert ListApps.search_dirs() == [
               "/Applications",
               "/System/Applications",
               Path.expand("~/Applications")
             ]
    end
  end

  describe "merge/1" do
    test "keeps only bundles, drops nested helpers, dedupes and sorts by name" do
      merged =
        ListApps.merge([
          ["/Applications/Zed.app", "/Applications/Notes.app", "/Applications/README.txt"],
          [
            "/Applications/Notes.app",
            "/Applications/Xcode.app/Contents/Applications/Helper.app",
            "/System/Applications/Music.app"
          ]
        ])

      assert Enum.map(merged, & &1.name) == ["Music", "Notes", "Zed"]
      assert Enum.map(merged, & &1.path) |> Enum.uniq() == Enum.map(merged, & &1.path)
      refute Enum.any?(merged, &String.contains?(&1.path, "Xcode.app/"))
    end

    test "sorting is case-insensitive, with the path as tiebreaker" do
      merged =
        ListApps.merge([
          ["/System/Applications/Notes.app", "/Applications/Notes.app", "/Applications/apple.app"]
        ])

      assert Enum.map(merged, & &1.path) == [
               "/Applications/apple.app",
               "/Applications/Notes.app",
               "/System/Applications/Notes.app"
             ]
    end

    test "no sources yields no apps" do
      assert ListApps.merge([[], []]) == []
    end
  end

  describe "filter/2" do
    setup do
      %{
        apps: [
          %{name: "Safari", path: "/Applications/Safari.app"},
          %{name: "Mail", path: "/Applications/Mail.app"},
          %{name: "System Settings", path: "/System/Applications/System Settings.app"}
        ]
      }
    end

    test "matches a case-insensitive substring", %{apps: apps} do
      assert ListApps.filter(apps, "SAF") |> Enum.map(& &1.name) == ["Safari"]
      assert ListApps.filter(apps, "s") |> Enum.map(& &1.name) == ["Safari", "System Settings"]
    end

    test "a blank filter keeps everything", %{apps: apps} do
      assert ListApps.filter(apps, nil) == apps
      assert ListApps.filter(apps, "") == apps
    end

    test "no match yields no apps", %{apps: apps} do
      assert ListApps.filter(apps, "nothing-here") == []
    end
  end

  describe "render/1" do
    test "one name — path line per app" do
      assert ListApps.render([
               %{name: "Mail", path: "/Applications/Mail.app"},
               %{name: "Music", path: "/System/Applications/Music.app"}
             ]) == "Mail — /Applications/Mail.app\nMusic — /System/Applications/Music.app"
    end
  end

  # Read-only: scanning the bundle directories and querying Spotlight has no
  # side effect on the machine.
  if @darwin? do
    describe "execute/2 on a real Mac" do
      test "finds the shipped system applications, including the Utilities folder" do
        result = execute(%{})
        body = Content.text_of(result.content)

        assert body =~ "/System/Applications/Utilities/Terminal.app"
        assert result.details.count > 0
      end

      test "framework-embedded background agents stay out of the listing" do
        body = execute(%{}).content |> Content.text_of()

        refute body =~ ".framework/"
        refute body =~ "/System/Library/CoreServices/"
      end

      test "the filter narrows the listing" do
        result = execute(%{"filter" => "terminal"})
        body = Content.text_of(result.content)

        assert body =~ "Terminal"
        refute body =~ "/System/Applications/Music.app"
      end

      test "the limit is honoured and reported" do
        result = execute(%{"limit" => 2})

        assert result.details.count == 2
        assert result.details.limit_reached == true
      end

      defp execute(args),
        do: ListApps.execute(args, %{cwd: File.cwd!(), call_id: "t", report: fn _ -> :ok end})
    end
  end
end
