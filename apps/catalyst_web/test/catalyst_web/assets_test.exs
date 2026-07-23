defmodule CatalystWeb.AssetsTest do
  # async: false — swaps the global :tailwind profile config.
  use ExUnit.Case, async: false

  alias CatalystWeb.Assets

  @marker "/* catalyst:extensions-source */"

  defp with_tailwind_profile(css_content) do
    dir = Path.join(System.tmp_dir!(), "catalyst_assets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "assets/css"))
    css = Path.join(dir, "assets/css/app.css")
    File.write!(css, css_content)

    original = Application.get_env(:tailwind, :catalyst_web)
    Application.put_env(:tailwind, :catalyst_web, args: ["--input=assets/css/app.css"], cd: dir)

    on_exit(fn ->
      Application.put_env(:tailwind, :catalyst_web, original)
      File.rm_rf!(dir)
    end)

    css
  end

  test "localize_extension_source rewrites the baked build-machine path" do
    css =
      with_tailwind_profile("""
      @source "../css";
      #{@marker}
      @source "/Users/someone-else/.catalyst/extensions";
      """)

    assert :ok = Assets.localize_extension_source()

    rewritten = File.read!(css)
    assert rewritten =~ ~s(@source "#{Catalyst.Extensions.dir()}";)
    refute rewritten =~ "someone-else"
    # Unmarked @source lines are left alone.
    assert rewritten =~ ~s(@source "../css";)
  end

  test "localize_extension_source is a no-op without the marker (dev css)" do
    css = with_tailwind_profile(~s(@source "../css";\n))
    before = File.read!(css)

    assert :ok = Assets.localize_extension_source()

    assert File.read!(css) == before
  end

  test "rebuild surfaces a localization failure instead of discarding it" do
    # A marked css that needs rewriting, but is not writable: localization
    # fails while the build itself may still proceed.
    css =
      with_tailwind_profile("""
      #{@marker}
      @source "/Users/someone-else/.catalyst/extensions";
      """)

    File.chmod!(css, 0o444)
    on_exit(fn -> File.chmod!(css, 0o644) end)

    # Point the esbuild profile into the same sandbox so a machine with the
    # real toolchain installed cannot rebuild the repo's actual assets from a
    # test (the entry file does not exist, so a real esbuild fails fast).
    tmp_dir = css |> Path.dirname() |> Path.dirname() |> Path.dirname()
    original_esbuild = Application.get_env(:esbuild, :catalyst_web)
    Application.put_env(:esbuild, :catalyst_web, args: ["js/app.js", "--bundle"], cd: tmp_dir)
    on_exit(fn -> Application.put_env(:esbuild, :catalyst_web, original_esbuild) end)

    {result, log} = ExUnit.CaptureLog.with_log(fn -> Assets.rebuild() end)

    assert log =~ "could not localize extensions @source"

    # Never a bare :ok — the failure is either carried as a warning on the
    # success shape or superseded by the build's own error (when the
    # esbuild/tailwind toolchain is unavailable in this environment).
    case result do
      {:ok, %{warnings: [{:localize_extension_source, _reason}]}} -> :ok
      {:error, _build_unavailable_or_failed} -> :ok
      other -> flunk("expected surfaced localization failure, got: #{inspect(other)}")
    end
  end
end
