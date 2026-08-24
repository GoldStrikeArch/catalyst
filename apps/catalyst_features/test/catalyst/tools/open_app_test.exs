defmodule Catalyst.Tools.OpenAppTest do
  # Nothing here launches an application: the tool's whole decision surface is
  # `argv/1`, which is pure, and `execute/2` only resolves the path before
  # shelling out. Actually running `open` would put a window on the user's
  # screen from a test run, so it is deliberately not exercised.
  use ExUnit.Case, async: true

  doctest Catalyst.Tools.OpenApp

  alias Catalyst.Tools.OpenApp

  describe "registration" do
    test "is sequential and gated behind computer use" do
      assert OpenApp.name() == "open_app"
      assert OpenApp.execution_mode() == :sequential
      assert OpenApp.capabilities() == [:computer_use]
    end
  end

  describe "argv/1" do
    test "maps each target onto its open(1) flag" do
      assert OpenApp.argv(%{"app" => "Safari"}) == {:ok, ["-a", "Safari"]}

      assert OpenApp.argv(%{"bundle_id" => "com.apple.Safari"}) ==
               {:ok, ["-b", "com.apple.Safari"]}

      assert OpenApp.argv(%{"path" => "/tmp/a.txt"}) == {:ok, ["/tmp/a.txt"]}
      assert OpenApp.argv(%{"url" => "https://example.com"}) == {:ok, ["https://example.com"]}
    end

    test "reveal adds -R and requires a path" do
      assert OpenApp.argv(%{"path" => "/tmp/a.txt", "reveal" => true}) ==
               {:ok, ["-R", "/tmp/a.txt"]}

      assert OpenApp.argv(%{"url" => "https://example.com", "reveal" => true}) ==
               {:error, :reveal_needs_path}
    end

    test "an app and a path combine into 'open this file in that app'" do
      assert OpenApp.argv(%{"app" => "Preview", "path" => "/tmp/a.pdf"}) ==
               {:ok, ["-a", "Preview", "/tmp/a.pdf"]}
    end

    test "flags precede positionals, and --args comes last" do
      assert OpenApp.argv(%{
               "app" => "Terminal",
               "path" => "/tmp/x",
               "args" => ["one", "two"]
             }) == {:ok, ["-a", "Terminal", "/tmp/x", "--args", "one", "two"]}
    end

    test "blank values are ignored rather than emitting empty flags" do
      assert OpenApp.argv(%{"app" => "", "url" => "https://example.com"}) ==
               {:ok, ["https://example.com"]}

      assert OpenApp.argv(%{"app" => "", "path" => ""}) == {:error, :no_target}
    end

    test "requires at least one target" do
      assert OpenApp.argv(%{}) == {:error, :no_target}
      assert OpenApp.argv(%{"args" => ["x"]}) == {:error, :no_target}
      assert OpenApp.argv(%{"reveal" => false}) == {:error, :no_target}
    end

    test "a positional that open(1) would read as a flag is refused" do
      assert OpenApp.argv(%{"path" => "-R"}) == {:error, {:bad_target, "-R"}}
      assert OpenApp.argv(%{"url" => "--args"}) == {:error, {:bad_target, "--args"}}
    end

    test "args must be a list of strings" do
      assert OpenApp.argv(%{"app" => "Safari", "args" => "one"}) == {:error, {:bad_args, "one"}}
      assert OpenApp.argv(%{"app" => "Safari", "args" => [1]}) == {:error, {:bad_args, [1]}}
      assert OpenApp.argv(%{"app" => "Safari", "args" => []}) == {:ok, ["-a", "Safari"]}
    end
  end

  describe "execute/2 validation" do
    test "an empty request explains what is missing without shelling out" do
      assert_raise RuntimeError, ~r/at least one of: app, bundle_id, path, url/, fn ->
        OpenApp.execute(%{}, ctx())
      end
    end

    test "reveal without a path is refused" do
      assert_raise RuntimeError, ~r/`reveal` requires a `path`/, fn ->
        OpenApp.execute(%{"app" => "Finder", "reveal" => true}, ctx())
      end
    end

    test "a relative path is resolved against the session cwd before validation" do
      # The tmp cwd makes the resolved path absolute, which is the only reason
      # `notes.txt` is not later mistaken for a flag or resolved by `open` in
      # whatever directory the BEAM happens to sit in.
      assert_raise RuntimeError, ~r/`reveal` requires a `path`/, fn ->
        OpenApp.execute(%{"reveal" => true}, ctx("/tmp"))
      end
    end

    test "non-string args are refused" do
      assert_raise RuntimeError, ~r/must be a list of strings/, fn ->
        OpenApp.execute(%{"app" => "Safari", "args" => %{}}, ctx())
      end
    end
  end

  defp ctx(cwd \\ nil),
    do: %{cwd: cwd || File.cwd!(), call_id: "t", report: fn _ -> :ok end}
end
